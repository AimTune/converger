defmodule Converger.Partitions.Conversion do
  @moduledoc """
  Converts the plain (pre-#30) `activities` and `deliveries` tables into
  monthly partitioned tables: create partitioned shadow tables, copy in
  batches, swap. See docs/operations/migrations.md ("Partitioning
  activities and deliveries") and ADR-0034.

  Three phases, each idempotent and resumable:

  1. `prepare/2` - creates `activities_part` / `deliveries_part` with their
     monthly partitions and installs row triggers on the legacy tables that
     mirror every insert, update and delete into the shadow tables. Safe
     while the old release is serving traffic (`CREATE TRIGGER` takes a
     short `SHARE ROW EXCLUSIVE` lock, bounded by a lock timeout).
  2. `copy/2` - copies existing rows in primary-key order, `batch_size` rows
     per transaction (`SELECT ... FOR SHARE`, `INSERT ... ON CONFLICT DO
     NOTHING`), remembering its cursor in `partition_conversion_state`. Also
     safe online; run it with `Converger.Release.prepare_partitioning/0`
     before the maintenance window on large installations.
  3. `swap/2` - in one transaction: locks the legacy tables, copies whatever
     is left, verifies that row counts match, drops the triggers and the
     foreign keys that point at the legacy tables, renames `activities` to
     `activities_legacy` (same for deliveries) and the shadow tables to the
     real names. Needs the old release stopped: old code cannot write the
     new `deliveries` columns.

  `run/2` (called by the migration) does all three. It refuses to copy more
  than `:max_inline_rows` rows inside `bin/migrate` unless `prepare` and
  `copy` were run beforehand, so a large installation never ends up in an
  unplanned multi-hour maintenance window.

  Table names are resolved through `search_path`, which is how the tests run
  the conversion against legacy tables in a scratch schema.
  """

  require Logger

  alias Converger.Partitions

  @shadow %{"activities" => "activities_part", "deliveries" => "deliveries_part"}
  @state_table "partition_conversion_state"
  @zero_uuid "00000000-0000-0000-0000-000000000000"
  @default_batch_size 10_000
  @default_max_inline_rows 1_000_000

  @activity_columns ~w(id tenant_id conversation_id type sender text attachments metadata
                       idempotency_key inserted_at updated_at seq)
  # The legacy columns as of the migrations before 20261010300100 (including
  # the dead-letter replay columns of 20261010032000). swap/2 refuses to run
  # if the legacy table has a column the shadow table lacks.
  @delivery_columns ~w(id activity_id channel_id status attempts last_error delivered_at
                       metadata inserted_at updated_at sent_at read_at provider_message_id
                       retry_count retried_by retried_at)

  @doc "Whether `table` is already a partitioned table."
  def partitioned?(repo, table) do
    %{rows: rows} =
      repo.query!("SELECT relkind::text FROM pg_class WHERE oid = to_regclass($1)", [table],
        log: false
      )

    rows == [["p"]]
  end

  @doc "Whether both tables are partitioned (conversion done or fresh schema)."
  def converted?(repo), do: partitioned?(repo, "activities") and partitioned?(repo, "deliveries")

  @doc "Whether `prepare/2` has run (shadow tables and state exist)."
  def prepared?(repo) do
    Partitions.table_exists?(repo, @state_table) and
      Partitions.table_exists?(repo, @shadow["activities"]) and
      Partitions.table_exists?(repo, @shadow["deliveries"])
  end

  @doc """
  Migration entry point: prepare, copy and swap. No-op when already
  converted.

  Options: `:batch_size`, `:max_inline_rows` (default 1,000,000; also
  `PARTITION_MAX_INLINE_ROWS`), `:drop_empty_legacy` (default `true`: legacy
  tables that held no rows are dropped instead of kept), `:today`.
  """
  def run(repo, opts \\ []) do
    if converted?(repo) do
      :ok
    else
      check_inline_size!(repo, opts)
      prepare(repo, opts)
      copy(repo, opts)
      swap(repo, opts)
    end
  end

  defp check_inline_size!(repo, opts) do
    max_rows = Keyword.get_lazy(opts, :max_inline_rows, &max_inline_rows_from_env/0)

    if not prepared?(repo) do
      rows = count_upto(repo, "activities", max_rows + 1)

      if rows > max_rows do
        raise """
        activities has more than #{max_rows} rows. Converting it to a partitioned table inside
        bin/migrate would need a long maintenance window. Run the online copy first, while the
        old release is still serving traffic:

            bin/converger eval "Converger.Release.prepare_partitioning()"

        then stop the old release and run bin/migrate again (see docs/operations/migrations.md,
        "Partitioning activities and deliveries"). To copy inline anyway, set
        PARTITION_MAX_INLINE_ROWS to a larger value.
        """
      end
    end

    :ok
  end

  defp max_inline_rows_from_env do
    case System.get_env("PARTITION_MAX_INLINE_ROWS") do
      value when value in [nil, ""] -> @default_max_inline_rows
      value -> String.to_integer(value)
    end
  end

  defp count_upto(repo, table, limit) do
    %{rows: [[n]]} =
      repo.query!("SELECT count(*) FROM (SELECT 1 FROM #{table} LIMIT $1) AS s", [limit],
        timeout: :infinity
      )

    n
  end

  ## Phase 1: prepare

  @doc """
  Creates the shadow partitioned tables, their partitions (from the oldest
  legacy row's month to 12 months ahead) and the mirror triggers.
  Idempotent.
  """
  def prepare(repo, opts \\ []) do
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    # Fail before creating anything if the legacy schema has unknown columns.
    Enum.each(Partitions.tables(), &legacy_columns(repo, &1))

    repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@state_table} (
      table_name text PRIMARY KEY,
      cursor uuid NOT NULL DEFAULT '#{@zero_uuid}',
      copied bigint NOT NULL DEFAULT 0,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    for table <- Partitions.tables() do
      repo.query!(
        "INSERT INTO #{@state_table} (table_name) VALUES ($1) ON CONFLICT DO NOTHING",
        [table]
      )
    end

    Enum.each(shadow_ddl(), &repo.query!/1)

    from = oldest_month(repo) || Partitions.month_start(today)

    Partitions.ensure_partitions(
      repo: repo,
      today: today,
      from: Date.shift(from, month: -1),
      months_ahead: 12,
      parents: @shadow
    )

    install_triggers(repo)
    :ok
  end

  defp oldest_month(repo) do
    %{rows: [[oldest]]} =
      repo.query!("SELECT min(inserted_at) FROM activities", [], timeout: :infinity)

    oldest && Partitions.month_start(oldest)
  end

  @doc false
  def shadow_ddl do
    [
      """
      CREATE TABLE IF NOT EXISTS activities_part (
        id uuid NOT NULL DEFAULT uuid_generate_v4(),
        tenant_id uuid NOT NULL,
        conversation_id uuid NOT NULL,
        type text,
        sender text NOT NULL,
        text text,
        attachments jsonb DEFAULT '[]'::jsonb,
        metadata jsonb DEFAULT '{}'::jsonb,
        idempotency_key text,
        inserted_at timestamp without time zone NOT NULL,
        updated_at timestamp without time zone NOT NULL,
        seq bigint NOT NULL,
        CONSTRAINT activities_part_pkey PRIMARY KEY (id, inserted_at)
      ) PARTITION BY RANGE (inserted_at)
      """,
      "CREATE INDEX IF NOT EXISTS activities_part_tenant_id_id_index ON activities_part (tenant_id, id)",
      "CREATE INDEX IF NOT EXISTS activities_part_conversation_id_inserted_at_index ON activities_part (conversation_id, inserted_at)",
      "CREATE INDEX IF NOT EXISTS activities_part_idempotency_key_index ON activities_part (idempotency_key) WHERE idempotency_key IS NOT NULL",
      """
      CREATE TABLE IF NOT EXISTS deliveries_part (
        id uuid NOT NULL DEFAULT uuid_generate_v4(),
        activity_id uuid NOT NULL,
        channel_id uuid NOT NULL,
        status text NOT NULL DEFAULT 'pending',
        attempts integer DEFAULT 0,
        last_error text,
        delivered_at timestamp without time zone,
        metadata jsonb DEFAULT '{}'::jsonb,
        inserted_at timestamp without time zone NOT NULL,
        updated_at timestamp without time zone NOT NULL,
        sent_at timestamp without time zone,
        read_at timestamp without time zone,
        provider_message_id text,
        retry_count integer NOT NULL DEFAULT 0,
        retried_by character varying(255),
        retried_at timestamp without time zone,
        tenant_id uuid NOT NULL,
        activity_inserted_at timestamp without time zone NOT NULL,
        CONSTRAINT deliveries_part_pkey PRIMARY KEY (id, activity_inserted_at)
      ) PARTITION BY RANGE (activity_inserted_at)
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS deliveries_part_activity_id_channel_id_index ON deliveries_part (activity_id, channel_id, activity_inserted_at)",
      "CREATE INDEX IF NOT EXISTS deliveries_part_channel_id_index ON deliveries_part (channel_id)",
      "CREATE INDEX IF NOT EXISTS deliveries_part_status_index ON deliveries_part (status)",
      "CREATE INDEX IF NOT EXISTS deliveries_part_provider_message_id_index ON deliveries_part (provider_message_id) WHERE provider_message_id IS NOT NULL",
      "CREATE INDEX IF NOT EXISTS deliveries_part_channel_id_provider_message_id_index ON deliveries_part (channel_id, provider_message_id) WHERE provider_message_id IS NOT NULL",
      "CREATE INDEX IF NOT EXISTS deliveries_part_inserted_at_id_index ON deliveries_part (inserted_at, id)",
      "CREATE INDEX IF NOT EXISTS deliveries_part_tenant_id_id_index ON deliveries_part (tenant_id, id)",
      # Dead-letter lists (20261010032100).
      "CREATE INDEX IF NOT EXISTS deliveries_part_status_updated_at_id_index ON deliveries_part (status, updated_at, id)",
      "CREATE INDEX IF NOT EXISTS deliveries_part_channel_id_status_updated_at_id_index ON deliveries_part (channel_id, status, updated_at, id)"
    ]
  end

  defp install_triggers(repo) do
    a_columns = legacy_columns(repo, "activities")
    d_columns = legacy_columns(repo, "deliveries")

    a_cols = Enum.join(a_columns, ", ")
    a_new = Enum.map_join(a_columns, ", ", &"NEW.#{&1}")

    a_set =
      Enum.map_join(a_columns -- ~w(id inserted_at), ", ", &"#{&1} = EXCLUDED.#{&1}")

    d_cols = Enum.join(d_columns, ", ")
    d_new = Enum.map_join(d_columns, ", ", &"NEW.#{&1}")

    d_set =
      Enum.map_join(
        (d_columns -- ~w(id)) ++ ["tenant_id"],
        ", ",
        &"#{&1} = EXCLUDED.#{&1}"
      )

    repo.query!("""
    CREATE OR REPLACE FUNCTION converger_mirror_activities() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP IN ('DELETE', 'UPDATE') THEN
        IF TG_OP = 'DELETE' OR NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
          DELETE FROM activities_part WHERE id = OLD.id AND inserted_at = OLD.inserted_at;
        END IF;
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
      END IF;

      INSERT INTO activities_part (#{a_cols}) VALUES (#{a_new})
      ON CONFLICT (id, inserted_at) DO UPDATE SET #{a_set};
      RETURN NEW;
    END
    $$
    """)

    repo.query!("""
    CREATE OR REPLACE FUNCTION converger_mirror_deliveries() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      a_tenant uuid;
      a_inserted timestamp without time zone;
    BEGIN
      IF TG_OP IN ('DELETE', 'UPDATE') THEN
        IF TG_OP = 'DELETE' OR NEW.activity_id IS DISTINCT FROM OLD.activity_id THEN
          DELETE FROM deliveries_part WHERE id = OLD.id;
        END IF;
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
      END IF;

      SELECT a.tenant_id, a.inserted_at INTO a_tenant, a_inserted
      FROM activities a WHERE a.id = NEW.activity_id;

      IF NOT FOUND THEN
        RETURN NEW;
      END IF;

      INSERT INTO deliveries_part (#{d_cols}, tenant_id, activity_inserted_at)
      VALUES (#{d_new}, a_tenant, a_inserted)
      ON CONFLICT (id, activity_inserted_at) DO UPDATE SET #{d_set};
      RETURN NEW;
    END
    $$
    """)

    {:ok, _} =
      repo.transaction(fn ->
        repo.query!("SET LOCAL lock_timeout = '10s'")

        for table <- Partitions.tables() do
          repo.query!("DROP TRIGGER IF EXISTS converger_mirror ON #{table}")

          repo.query!(
            "CREATE TRIGGER converger_mirror AFTER INSERT OR UPDATE OR DELETE ON #{table} " <>
              "FOR EACH ROW EXECUTE FUNCTION converger_mirror_#{table}()"
          )
        end
      end)

    :ok
  end

  ## Phase 2: copy

  @doc """
  Copies legacy rows into the shadow tables in batches, resuming from the
  stored cursor. Returns `%{"activities" => copied, "deliveries" => copied}`
  for this call.

  Options: `:batch_size` (default 10,000), `:on_batch` (a 2-arity function
  called with the table and the running total, for progress output).
  """
  def copy(repo, opts \\ []) do
    batch = Keyword.get(opts, :batch_size, @default_batch_size)
    on_batch = Keyword.get(opts, :on_batch, fn _table, _total -> :ok end)

    Map.new(Partitions.tables(), fn table ->
      {table, copy_table(repo, table, batch, on_batch, 0)}
    end)
  end

  defp copy_table(repo, table, batch, on_batch, total) do
    n = copy_batch(repo, table, batch, 3)
    total = total + n

    if n > 0 do
      on_batch.(table, total)
      copy_table(repo, table, batch, on_batch, total)
    else
      total
    end
  end

  # A batch holds FOR SHARE locks on legacy rows while it inserts into the
  # shadow table; an application transaction that updates two of those rows
  # (and fires the mirror trigger) can deadlock with it. Postgres aborts one
  # side; the batch is simply retried.
  defp copy_batch(repo, table, batch, retries) do
    do_copy_batch(repo, table, batch)
  rescue
    error in Postgrex.Error ->
      if retries > 0 and error.postgres[:code] in [:deadlock_detected, :lock_not_available] and
           not repo.in_transaction?() do
        Process.sleep(100)
        copy_batch(repo, table, batch, retries - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp do_copy_batch(repo, table, batch) do
    {:ok, n} =
      repo.transaction(
        fn ->
          %{rows: [[cursor]]} =
            repo.query!(
              "SELECT cursor FROM #{@state_table} WHERE table_name = $1 FOR UPDATE",
              [table]
            )

          %{rows: [[n, last]]} =
            repo.query!(copy_sql(table, legacy_columns(repo, table)), [cursor, batch],
              timeout: :infinity
            )

          if n > 0 do
            repo.query!(
              "UPDATE #{@state_table} SET cursor = $2, copied = copied + $3, updated_at = now() WHERE table_name = $1",
              [table, last, n]
            )
          end

          n
        end,
        timeout: :infinity
      )

    n
  end

  @doc """
  Columns of the legacy `table` that are copied and mirrored: the known
  columns that exist there (older schemas may lack recent ones, which then
  take their defaults). Raises if the legacy table has a column the shadow
  table does not know, rather than silently dropping its data.
  """
  def legacy_columns(repo, table) do
    known = if table == "activities", do: @activity_columns, else: @delivery_columns

    %{rows: rows} =
      repo.query!(
        "SELECT attname FROM pg_attribute WHERE attrelid = to_regclass($1) " <>
          "AND attnum > 0 AND NOT attisdropped",
        [table]
      )

    present = List.flatten(rows)

    case present -- known do
      [] ->
        Enum.filter(known, &(&1 in present))

      unknown ->
        raise "partition conversion: #{table} has columns #{inspect(unknown)} that the " <>
                "partitioned table does not have; nothing was changed"
    end
  end

  # FOR SHARE makes a concurrent UPDATE or DELETE either finish first (and
  # the batch sees its result) or wait for the batch: a copied row can never
  # overwrite a newer version the mirror trigger already wrote, and a
  # deleted row is never resurrected.
  defp copy_sql("activities", columns) do
    cols = Enum.join(columns, ", ")

    """
    WITH batch AS (
      SELECT #{cols} FROM activities WHERE id > $1 ORDER BY id LIMIT $2 FOR SHARE
    ), ins AS (
      INSERT INTO activities_part (#{cols}) SELECT #{cols} FROM batch ON CONFLICT DO NOTHING
    )
    SELECT count(*), (SELECT id FROM batch ORDER BY id DESC LIMIT 1) FROM batch
    """
  end

  defp copy_sql("deliveries", columns) do
    cols = Enum.join(columns, ", ")
    b_cols = Enum.map_join(columns, ", ", &"b.#{&1}")

    """
    WITH batch AS (
      SELECT #{cols} FROM deliveries WHERE id > $1 ORDER BY id LIMIT $2 FOR SHARE
    ), ins AS (
      INSERT INTO deliveries_part (#{cols}, tenant_id, activity_inserted_at)
      SELECT #{b_cols}, a.tenant_id, a.inserted_at
      FROM batch b JOIN activities a ON a.id = b.activity_id
      ON CONFLICT DO NOTHING
    )
    SELECT count(*), (SELECT id FROM batch ORDER BY id DESC LIMIT 1) FROM batch
    """
  end

  @doc "Copy progress: `%{table => %{copied: n, cursor: uuid}}`."
  def progress(repo) do
    %{rows: rows} = repo.query!("SELECT table_name, copied, cursor FROM #{@state_table}")

    Map.new(rows, fn [table, copied, cursor] ->
      {table, %{copied: copied, cursor: Ecto.UUID.load!(cursor)}}
    end)
  end

  ## Phase 3: swap

  @doc """
  Swaps the shadow tables in. Must run with no writers on the legacy tables
  (maintenance window). Raises, and rolls everything back, if the row counts
  do not match after the final catch-up copy.

  Options: `:drop_empty_legacy` (default `true`), `:lock_timeout_ms`
  (default 10,000), `:batch_size`, `:today`.
  """
  def swap(repo, opts \\ []) do
    drop_empty? = Keyword.get(opts, :drop_empty_legacy, true)
    lock_timeout = Keyword.get(opts, :lock_timeout_ms, 10_000)
    batch = Keyword.get(opts, :batch_size, @default_batch_size)

    {:ok, result} =
      repo.transaction(
        fn ->
          repo.query!("SET LOCAL lock_timeout = '#{lock_timeout}ms'")
          repo.query!("LOCK TABLE activities, deliveries IN ACCESS EXCLUSIVE MODE")

          for table <- Partitions.tables() do
            copy_table(repo, table, batch, fn _, _ -> :ok end, 0)
          end

          counts = verify_counts!(repo)
          drop_triggers(repo)
          drop_legacy_foreign_keys(repo)

          for table <- Partitions.tables() do
            rename_table(repo, table, "#{table}_legacy")
            rename_table(repo, @shadow[table], table)
          end

          repo.query!("DROP TABLE #{@state_table}")

          legacy =
            for {table, n} <- counts, into: %{} do
              if n == 0 and drop_empty? do
                repo.query!("DROP TABLE #{table}_legacy")
                {table, :dropped}
              else
                {table, n}
              end
            end

          legacy
        end,
        timeout: :infinity
      )

    Partitions.ensure_partitions(
      repo: repo,
      today: Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    )

    Logger.info("Partitioned activities and deliveries", legacy: inspect(result))
    {:ok, result}
  end

  defp verify_counts!(repo) do
    Map.new(Partitions.tables(), fn table ->
      %{rows: [[legacy]]} = repo.query!("SELECT count(*) FROM #{table}", [], timeout: :infinity)

      %{rows: [[shadow]]} =
        repo.query!("SELECT count(*) FROM #{@shadow[table]}", [], timeout: :infinity)

      if legacy != shadow do
        raise "partition conversion: #{table} has #{legacy} rows but #{@shadow[table]} has " <>
                "#{shadow}; nothing was swapped"
      end

      {table, legacy}
    end)
  end

  defp drop_triggers(repo) do
    for table <- Partitions.tables() do
      repo.query!("DROP TRIGGER IF EXISTS converger_mirror ON #{table}")
      repo.query!("DROP FUNCTION IF EXISTS converger_mirror_#{table}()")
    end
  end

  # Foreign keys from or to the legacy tables (activities -> tenants and
  # conversations, deliveries -> activities and channels, attachments ->
  # activities). The partitioned tables have none, see ADR-0034.
  defp drop_legacy_foreign_keys(repo) do
    %{rows: rows} =
      repo.query!("""
      SELECT conrelid::regclass::text, conname
      FROM pg_constraint
      WHERE contype = 'f'
        AND (conrelid IN (to_regclass('activities'), to_regclass('deliveries'))
             OR confrelid IN (to_regclass('activities'), to_regclass('deliveries')))
      """)

    for [table, name] <- rows do
      repo.query!(~s(ALTER TABLE #{table} DROP CONSTRAINT "#{name}"))
    end
  end

  # Renames a table and every index on it whose name starts with the old
  # table name, so `activities_part_pkey` becomes `activities_pkey` once the
  # legacy `activities_pkey` has become `activities_legacy_pkey`.
  defp rename_table(repo, from, to) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT i.relname FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid
        WHERE x.indrelid = to_regclass($1)
        """,
        [from]
      )

    repo.query!("ALTER TABLE #{from} RENAME TO #{to}")

    for [index] <- rows, String.starts_with?(index, from <> "_") do
      new_name = to <> String.trim_leading(index, from)
      repo.query!(~s(ALTER INDEX "#{index}" RENAME TO "#{new_name}"))
    end

    :ok
  end

  @doc """
  Drops the `*_legacy` tables kept by `swap/2` once the partitioned tables
  are verified. Irreversible.
  """
  def drop_legacy_tables(repo) do
    repo.query!("DROP TABLE IF EXISTS deliveries_legacy, activities_legacy")
    :ok
  end
end
