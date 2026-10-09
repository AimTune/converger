defmodule Converger.Partitions do
  @moduledoc """
  Monthly range partitions of `activities` and `deliveries` (issue #30,
  [ADR-0034](docs/adr/0034-monthly-partitioning-and-per-tenant-retention.md)).

  * `activities` is partitioned by `inserted_at`.
  * `deliveries` is partitioned by `activity_inserted_at`, the `inserted_at`
    of the activity it delivers, so a delivery always lives in the same month
    as its activity and both are archived and dropped together.

  Partitions are named `<table>_pYYYY_MM` (`activities_p2026_10`) and cover
  `[first day of the month, first day of the next month)` in UTC.

  New partitions are created as plain tables, given their per-partition
  unique indexes and then attached (`ATTACH PARTITION` only takes a
  `SHARE UPDATE EXCLUSIVE` lock on the parent, so reads and writes continue).
  `ensure_partitions/1` keeps the current month and the next
  `:months_ahead` months (default 3) in place; it runs from the migration,
  on application start and daily from
  `Converger.Workers.PartitionMaintenanceWorker`. There is deliberately no
  `DEFAULT` partition: it would make `DETACH PARTITION ... CONCURRENTLY`
  impossible.

  Retention removes a month with `detach/3` (concurrently by default, which
  does not block writers) followed by `drop_detached/3` (a plain `DROP TABLE`
  of a table nobody reads any more, milliseconds).
  """

  require Logger

  @tables ~w(activities deliveries)
  @leaf_regex ~r/^(activities|deliveries)_p(\d{4})_(\d{2})$/

  @type table :: String.t()

  @doc "The partitioned tables."
  def tables, do: @tables

  @doc "The partition key column of `table`."
  def partition_key("activities"), do: "inserted_at"
  def partition_key("deliveries"), do: "activity_inserted_at"

  @doc "Name of the partition of `table` holding `month` (any date in the month)."
  def leaf_name(table, %Date{} = month) when table in @tables do
    m = month_start(month)
    "#{table}_p#{m.year}_#{m.month |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "Parses a partition name into `{table, month}`, or `:error`."
  def parse_leaf_name(name) when is_binary(name) do
    case Regex.run(@leaf_regex, name) do
      [_, table, year, month] ->
        {table, Date.new!(String.to_integer(year), String.to_integer(month), 1)}

      _ ->
        :error
    end
  end

  @doc "First day of the month of `date`."
  def month_start(%Date{} = date), do: Date.beginning_of_month(date)

  def month_start(%DateTime{} = dt), do: dt |> DateTime.to_date() |> month_start()
  def month_start(%NaiveDateTime{} = dt), do: dt |> NaiveDateTime.to_date() |> month_start()

  @doc "First day of the month after the month of `date`."
  def next_month(%Date{} = date), do: date |> month_start() |> Date.shift(month: 1)

  @doc "`YYYY-MM` label of a month."
  def month_label(%Date{} = date) do
    m = month_start(date)
    "#{m.year}-#{m.month |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "Parses `YYYY-MM` into the first day of that month."
  def parse_month(<<y::binary-size(4), "-", m::binary-size(2)>>) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {:ok, date} <- Date.new(year, month, 1) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  def parse_month(_), do: :error

  @doc """
  Months from `from` to `to` (inclusive, first days of the month).
  """
  def months_between(%Date{} = from, %Date{} = to) do
    from = month_start(from)
    to = month_start(to)

    Stream.iterate(from, &next_month/1)
    |> Enum.take_while(&(Date.compare(&1, to) != :gt))
  end

  @doc """
  Creates any missing partition from the previous month to `:months_ahead`
  months ahead (default from `config :converger, Converger.Partitions`, 3).

  Options: `:repo`, `:today`, `:months_ahead`, `:from` (an earlier first
  month, e.g. for tests or imports), `:parents` (`%{"activities" => name}`,
  used while converting legacy tables).

  Returns the names of the partitions it created.
  """
  def ensure_partitions(opts \\ []) do
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    ahead = Keyword.get(opts, :months_ahead, config(:months_ahead, 3))
    from = Keyword.get(opts, :from, today |> month_start() |> Date.shift(month: -1))
    months = months_between(from, Date.shift(month_start(today), month: ahead))

    for table <- @tables, month <- months, reduce: [] do
      acc ->
        case create_partition(table, month, opts) do
          {:ok, :created} -> [leaf_name(table, month) | acc]
          {:ok, :exists} -> acc
          {:error, reason} -> log_create_error(table, month, reason, acc)
        end
    end
    |> Enum.reverse()
  end

  defp log_create_error(table, month, reason, acc) do
    Logger.error("Could not create partition",
      partition: leaf_name(table, month),
      reason: inspect(reason)
    )

    acc
  end

  @doc """
  Creates and attaches the partition of `table` for `month`.

  Returns `{:ok, :created}`, `{:ok, :exists}` (already attached) or
  `{:error, :detached_exists}` when a table with the partition's name exists
  but is detached: that is a month retention has detached and not yet
  dropped, and it is never re-attached implicitly.

  Options: `:repo`, `:parents`.
  """
  def create_partition(table, %Date{} = month, opts \\ []) when table in @tables do
    repo = repo(opts)
    parent = parent_name(table, opts)
    leaf = leaf_name(table, month)

    cond do
      attached?(repo, parent, leaf) ->
        {:ok, :exists}

      table_exists?(repo, leaf) ->
        {:error, :detached_exists}

      true ->
        do_create(repo, table, parent, leaf, month)
    end
  end

  defp do_create(repo, table, parent, leaf, month) do
    from = month_start(month)
    to = next_month(month)

    statements =
      [
        "SET LOCAL lock_timeout = '#{config(:lock_timeout_ms, 5_000)}ms'",
        "CREATE TABLE #{leaf} (LIKE #{parent} INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE)"
      ] ++
        leaf_index_statements(table, leaf) ++
        [
          "ALTER TABLE #{parent} ATTACH PARTITION #{leaf} FOR VALUES FROM ('#{from} 00:00:00') TO ('#{to} 00:00:00')"
        ]

    repo.transaction(fn -> Enum.each(statements, &repo.query!(&1, [], log: false)) end)
    |> case do
      {:ok, _} -> {:ok, :created}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Postgrex.Error ->
      # Another node created it at the same moment.
      if error.postgres[:code] in [:duplicate_table, :duplicate_object] and
           attached?(repo, parent, leaf),
         do: {:ok, :exists},
         else: {:error, error}
  end

  @doc """
  Unique indexes that exist on every partition but not on the parent.

  Postgres requires a unique index on a partitioned table to contain the
  partition key, which `(conversation_id, seq)` and
  `(conversation_id, idempotency_key)` do not. They are therefore unique per
  partition; global uniqueness is guaranteed by the application (see
  ADR-0034). For `deliveries` the parent has a real unique index
  `(activity_id, channel_id, activity_inserted_at)`; it is created on the
  partition up front only so its name is predictable for
  `Ecto.Changeset.unique_constraint/3`.
  """
  def leaf_index_statements("activities", leaf) do
    [
      "CREATE UNIQUE INDEX IF NOT EXISTS #{leaf}_conversation_id_seq_index ON #{leaf} (conversation_id, seq)",
      "CREATE UNIQUE INDEX IF NOT EXISTS #{leaf}_conversation_id_idempotency_key_index ON #{leaf} (conversation_id, idempotency_key) WHERE idempotency_key IS NOT NULL"
    ]
  end

  def leaf_index_statements("deliveries", leaf) do
    [
      "CREATE UNIQUE INDEX IF NOT EXISTS #{leaf}_activity_id_channel_id_index ON #{leaf} (activity_id, channel_id, activity_inserted_at)"
    ]
  end

  @doc """
  Attached partitions of `table`, oldest first:
  `[%{name: ..., month: ~D[...], detach_pending: boolean}]`.
  """
  def attached(table, opts \\ []) when table in @tables do
    repo = repo(opts)

    %{rows: rows} =
      repo.query!(
        """
        SELECT c.relname, i.inhdetachpending
        FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = to_regclass($1) AND c.relkind = 'r'
        """,
        [parent_name(table, opts)],
        log: false
      )

    rows
    |> Enum.flat_map(fn [name, pending] ->
      case parse_leaf_name(name) do
        {^table, month} -> [%{name: name, month: month, detach_pending: pending}]
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.month, Date)
  end

  @doc """
  Tables named like a partition of `table` that are not attached: months
  detached by retention whose archive has not finished yet. Oldest first.
  """
  def detached(table, opts \\ []) when table in @tables do
    repo = repo(opts)

    %{rows: rows} =
      repo.query!(
        """
        SELECT c.relname
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r' AND n.nspname = current_schema()
          AND c.relname ~ $1
          AND NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid)
        """,
        ["^#{table}_p[0-9]{4}_[0-9]{2}$"],
        log: false
      )

    rows
    |> Enum.map(fn [name] ->
      {^table, month} = parse_leaf_name(name)
      %{name: name, month: month}
    end)
    |> Enum.sort_by(& &1.month, Date)
  end

  @doc """
  Detaches the partition of `table` for `month`.

  With `concurrently: true` (the default, `config :converger,
  Converger.Partitions, detach_concurrently: true`) this is
  `DETACH PARTITION ... CONCURRENTLY`: it waits for transactions that
  started before it but never blocks reads or writes on the parent. It
  cannot run inside a transaction. A detach that was interrupted half way
  (`inhdetachpending`) is completed with `FINALIZE`.

  Returns `:ok` (also when the partition is already detached or missing).
  """
  def detach(table, %Date{} = month, opts \\ []) when table in @tables do
    repo = repo(opts)
    parent = parent_name(table, opts)
    leaf = leaf_name(table, month)
    concurrently = Keyword.get(opts, :concurrently, config(:detach_concurrently, true))

    case Enum.find(attached(table, opts), &(&1.name == leaf)) do
      nil ->
        :ok

      %{detach_pending: true} ->
        repo.query!("ALTER TABLE #{parent} DETACH PARTITION #{leaf} FINALIZE", [],
          timeout: :infinity
        )

        :ok

      %{detach_pending: false} ->
        mode = if concurrently, do: " CONCURRENTLY", else: ""

        repo.query!("ALTER TABLE #{parent} DETACH PARTITION #{leaf}#{mode}", [],
          timeout: :infinity
        )

        :ok
    end
  end

  @doc """
  Drops the detached partition table of `table` for `month`. Refuses
  (`{:error, :attached}`) while it is still attached.
  """
  def drop_detached(table, %Date{} = month, opts \\ []) when table in @tables do
    repo = repo(opts)
    leaf = leaf_name(table, month)

    cond do
      attached?(repo, parent_name(table, opts), leaf) ->
        {:error, :attached}

      table_exists?(repo, leaf) ->
        # Only the detached table itself is locked; nothing references it.
        {:ok, _} =
          repo.transaction(fn ->
            repo.query!("SET LOCAL lock_timeout = '#{config(:lock_timeout_ms, 5_000)}ms'")
            repo.query!("DROP TABLE #{leaf}")
          end)

        :ok

      true ->
        :ok
    end
  end

  @doc "Whether a table (or partition) named `name` exists in the current schema."
  def table_exists?(repo \\ Converger.Repo, name) do
    %{rows: [[exists]]} =
      repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relname = $1 AND n.nspname = current_schema()
        )
        """,
        [name],
        log: false
      )

    exists
  end

  defp attached?(repo, parent, leaf) do
    %{rows: [[attached]]} =
      repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE i.inhparent = to_regclass($1) AND c.relname = $2 AND n.nspname = current_schema()
        )
        """,
        [parent, leaf],
        log: false
      )

    attached
  end

  @doc """
  Months for which `table` has a partition, attached or detached.
  """
  def months(table, opts \\ []) do
    (attached(table, opts) ++ detached(table, opts))
    |> Enum.map(& &1.month)
    |> Enum.uniq()
    |> Enum.sort(Date)
  end

  @doc """
  Supervisor children that create missing partitions once on boot (a
  one-off `Task`, so a database hiccup never stops the application; the
  daily `PartitionMaintenanceWorker` retries). Disabled with
  `ensure_on_boot: false`.
  """
  def boot_children do
    if config(:ensure_on_boot, true) do
      [
        Supervisor.child_spec(
          {Task,
           fn ->
             try do
               ensure_partitions()
             rescue
               error ->
                 Logger.error("Partition check on boot failed: #{Exception.message(error)}")
             end
           end},
          id: :ensure_partitions
        )
      ]
    else
      []
    end
  end

  defp parent_name(table, opts) do
    opts |> Keyword.get(:parents, %{}) |> Map.get(table, table)
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Converger.Repo)

  @doc false
  def config(key, default) do
    :converger |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
