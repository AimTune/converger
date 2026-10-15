defmodule Converger.Partition100MTest do
  @moduledoc """
  Partition archive and drop on a large dataset (issue #192, ADR-0034).

  Driven by `test/load/partition_100m/run.sh`, which starts its own Postgres
  and MinIO and sets the environment below; see docs/benchmarks/index.md.
  Never run it against a database you care about: it seeds tens of
  gigabytes and drops a month.

  1. Seeds `P100M_ROWS` rows (default 100,000,000) across `activities` and
     `deliveries` (`P100M_ACTIVITY_SHARE`, default 0.6), `P100M_MONTHS`
     monthly partitions ending 2023-12 and `P100M_TENANTS` tenants, with
     `INSERT ... SELECT generate_series` in batches. Each month is loaded
     into a plain table, indexed (the per-partition unique indexes of
     `Converger.Partitions` plus every index of the parent), vacuumed and
     attached, so the partitions have exactly the production indexes. A
     seeded database is reused when the configuration matches.
  2. Starts `P100M_WRITERS` writers inserting activities through
     `Converger.Activities.create_activity/2` into the current month at
     `P100M_WRITER_RATE` inserts per second each, recording every latency.
  3. After `P100M_BASELINE_S` seconds runs the production retention path,
     `Converger.Retention.run/1` for the oldest month, against MinIO:
     `DETACH PARTITION ... CONCURRENTLY`, export, verification and
     `DROP TABLE`. The phases are timed from the repo's query telemetry.
  4. Reads every archived object back (SHA-256 and line count per tenant
     and table, compared with the counts taken before the detach) and
     re-imports `P100M_REIMPORT_TENANTS` tenants with
     `Converger.Archive.import_tenant_month/2`, the documented path.
  5. Writes `results.json` and `report.md` to `P100M_OUT`.
  """
  use ExUnit.Case, async: false

  alias Converger.{Activities, Archive, Partitions, Repo, Retention}
  alias Converger.Uploads.S3Storage
  alias Converger.Uploads.Signers.SigV4
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :partition_100m
  @moduletag timeout: :infinity

  # The newest seeded month. Seeded months must not exist yet: the test
  # helper creates partitions from 2024-01 on.
  @last_month ~D[2023-12-01]
  @tenant_prefix "p100m-tenant-"
  @bucket "converger-p100m-archive"

  ## Configuration

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value |> String.replace("_", "") |> String.to_integer()
    end
  end

  defp env_float(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value |> Float.parse() |> elem(0)
    end
  end

  defp settings do
    %{
      rows: env_int("P100M_ROWS", 100_000_000),
      activity_share: env_float("P100M_ACTIVITY_SHARE", 0.6),
      months: env_int("P100M_MONTHS", 6),
      tenants: env_int("P100M_TENANTS", 8),
      conversations_per_tenant: env_int("P100M_CONVERSATIONS", 2_000),
      seed_batch: env_int("P100M_SEED_BATCH", 1_000_000),
      seed_jobs: env_int("P100M_SEED_JOBS", 4),
      writers: env_int("P100M_WRITERS", 8),
      writer_rate: env_int("P100M_WRITER_RATE", 25),
      baseline_s: env_int("P100M_BASELINE_S", 30),
      after_s: env_int("P100M_AFTER_S", 15),
      reimport_tenants: env_int("P100M_REIMPORT_TENANTS", 1),
      part_rows: env_int("P100M_PART_ROWS", 50_000),
      minio_endpoint: System.get_env("P100M_MINIO_ENDPOINT", "http://127.0.0.1:19000"),
      out: System.get_env("P100M_OUT", Path.join(System.tmp_dir!(), "converger-p100m")),
      hardware_file: System.get_env("P100M_HARDWARE")
    }
  end

  defp seeded_months(n), do: for(i <- (n - 1)..0//-1, do: Date.shift(@last_month, month: -i))

  ## The run

  test "a month of a large dataset is archived, verified and dropped without blocking writers" do
    if System.get_env("P100M_CONFIRM") != "1",
      do:
        flunk("run this through test/load/partition_100m/run.sh (it seeds a throwaway database)")

    :ok = Sandbox.checkout(Repo, sandbox: false)
    s = settings()
    File.mkdir_p!(s.out)

    log("Postgres: #{pg_version()}")
    seed = ensure_seeded(s, seeded_months(s.months))

    # A kept database (P100M_KEEP=1) is reused: each run archives the oldest
    # month still there.
    months = Enum.filter(seeded_months(s.months), &table_exists?("activities", &1))
    if months == [], do: flunk("every seeded month was archived already; tear the database down")
    oldest = hd(months)

    sizes = sizes(months)

    log(
      "dataset: #{sizes.rows} rows, #{fmt_bytes(sizes.total_bytes)} in #{length(months)} months"
    )

    configure_archive(s)
    tenants_before = counts_by_tenant(oldest)
    oldest_rows = tenants_before |> Map.values() |> Enum.sum()
    log("oldest month #{Partitions.month_label(oldest)}: #{oldest_rows} rows")

    writer_tenant = writer_fixture()

    :telemetry.attach_many(
      "p100m",
      [[:converger, :repo, :query], [:converger, :archive, :part]],
      &__MODULE__.handle_event/4,
      self()
    )

    t0 = System.monotonic_time()
    tasks = for i <- 1..s.writers, do: start_writer(writer_tenant, i, s.writer_rate, t0, self())
    for _ <- tasks, do: assert_receive({:writer_ready, _}, 30_000)
    log("#{s.writers} writers at #{s.writer_rate}/s each; baseline #{s.baseline_s} s")
    Process.sleep(s.baseline_s * 1_000)

    wal_before = wal_lsn()
    op_start = now_ms(t0)
    log("retention: detach, archive to MinIO, verify, drop #{Partitions.month_label(oldest)}")

    result = Retention.run(today: Date.utc_today(), months: [oldest])

    op_end = now_ms(t0)
    wal_after = wal_lsn()

    log(
      "retention finished in #{Float.round((op_end - op_start) / 1000, 1)} s: #{inspect(result)}"
    )

    Process.sleep(s.after_s * 1_000)
    samples = stop_writers(tasks)
    :telemetry.detach("p100m")
    events = drain_events(t0)

    {:ok, [%{action: :partition_dropped, rows: dropped_rows}]} = result
    phases = phases(events, op_start, op_end)
    writer_stats = writer_stats(samples, op_start, op_end, phases, s.baseline_s)
    wal_bytes = wal_diff(wal_after, wal_before)

    log("reading the archive back")
    readback = read_back(oldest, tenants_before)
    reimport = reimport(oldest, tenants_before, s.reimport_tenants)

    results = %{
      issue: 192,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      settings: Map.drop(s, [:out, :hardware_file]),
      hardware: hardware(s.hardware_file),
      postgres: postgres_info(),
      seed: seed,
      sizes: sizes,
      oldest_month: %{
        month: Partitions.month_label(oldest),
        rows_by_table: rows_by_table(tenants_before),
        rows: oldest_rows,
        bytes: sizes.by_month |> Enum.find(&(&1.month == Partitions.month_label(oldest))),
        dropped_rows: dropped_rows,
        still_exists: Enum.any?(Partitions.tables(), &table_exists?(&1, oldest))
      },
      operation: Map.merge(phases, %{total_ms: op_end - op_start, wal_bytes: wal_bytes}),
      archive: archive_summary(oldest, events),
      writers: writer_stats,
      readback: readback,
      reimport: reimport
    }

    results = Map.put(results, :projection, projection(results))

    File.write!(Path.join(s.out, "results.json"), Jason.encode_to_iodata!(results, pretty: true))
    File.write!(Path.join(s.out, "report.md"), report(results))

    # Every insert, for plotting latency over time against the phases.
    File.write!(
      Path.join(s.out, "writers.csv"),
      [
        "at_ms,latency_us,outcome\n"
        | samples
          |> Enum.sort()
          |> Enum.map(fn {at, us, outcome} -> "#{at},#{us},#{outcome}\n" end)
      ]
    )

    IO.puts("\n" <> report(results))

    assert dropped_rows == rows_by_table(tenants_before)
    refute results.oldest_month.still_exists
    assert readback.counts_match, "archived row counts differ from the partition"
    assert readback.checksums_ok
    assert Enum.all?(reimport.tenants, & &1.counts_match)
    assert writer_stats.during.count > 0, "writers made no progress during the operation"
  end

  ## Seeding

  defp ensure_seeded(s, months) do
    Repo.query!("CREATE TABLE IF NOT EXISTS p100m_seed (key text PRIMARY KEY, value jsonb)")
    config = Map.take(s, [:rows, :activity_share, :months, :tenants, :conversations_per_tenant])

    case Repo.query!("SELECT value FROM p100m_seed WHERE key = 'seed'") do
      %{rows: [[%{"config" => stored} = value]]} ->
        if stored == Jason.decode!(Jason.encode!(config)) do
          log("reusing the seeded dataset (#{s.rows} rows)")
          value |> Map.drop(["config"]) |> Map.put("reused", true)
        else
          flunk("the database holds a different seed (#{inspect(stored)}); tear it down first")
        end

      %{rows: []} ->
        if Enum.any?(months, fn m -> Enum.any?(Partitions.tables(), &table_exists?(&1, m)) end),
          do: flunk("seeded months exist without a completed seed; tear the database down first")

        seed(s, months, config)
    end
  end

  defp seed(s, months, config) do
    {tenants, channels} = seed_tenants(s.tenants)
    n_months = length(months)
    activities = round(s.rows * s.activity_share)
    deliveries = s.rows - activities
    a_per = split(activities, n_months)
    d_per = split(deliveries, n_months)
    offsets = Enum.scan([0 | Enum.drop(a_per, -1)], &+/2)

    log(
      "seeding #{activities} activities + #{deliveries} deliveries over #{n_months} months, " <>
        "#{s.tenants} tenants x #{s.conversations_per_tenant} conversations"
    )

    wal0 = wal_lsn()
    started = System.monotonic_time()

    seed_conversations(
      tenants,
      channels,
      s,
      hd(months),
      div(activities, s.tenants * s.conversations_per_tenant) + 1
    )

    ctx = %{
      tenants: tenants,
      channels: channels,
      t: s.tenants,
      c: s.conversations_per_tenant,
      batch: s.seed_batch
    }

    jobs =
      for {{month, a_m, d_m, off}, _i} <-
            Enum.with_index(Enum.zip([months, a_per, d_per, offsets])),
          table <- Partitions.tables() do
        {table, month, a_m, d_m, off}
      end

    jobs
    |> Task.async_stream(
      fn job ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        seed_partition(job, ctx)
      end,
      max_concurrency: max(s.seed_jobs, 1),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.each(fn {:ok, _} -> :ok end)

    Repo.query!("ANALYZE activities", [], timeout: :infinity)
    Repo.query!("ANALYZE deliveries", [], timeout: :infinity)
    Repo.query!("CHECKPOINT", [], timeout: :infinity)

    seed_ms = ms_since(started)
    wal = wal_diff(wal_lsn(), wal0)
    log("seeded in #{Float.round(seed_ms / 1000, 1)} s, WAL #{fmt_bytes(wal)}")

    value = %{
      "config" => config,
      "seconds" => Float.round(seed_ms / 1000, 1),
      "rows_per_second" => round(s.rows / max(seed_ms / 1000, 0.001)),
      "wal_bytes" => wal,
      "activities" => activities,
      "deliveries" => deliveries,
      "seed_jobs" => s.seed_jobs
    }

    Repo.query!("INSERT INTO p100m_seed (key, value) VALUES ('seed', $1)", [value])
    value |> Map.drop(["config"]) |> Map.put("reused", false)
  end

  defp split(total, n) do
    base = div(total, n)
    for i <- 0..(n - 1), do: if(i < rem(total, n), do: base + 1, else: base)
  end

  defp seed_tenants(n) do
    %{rows: existing} =
      Repo.query!("SELECT count(*) FROM tenants WHERE name LIKE $1", [@tenant_prefix <> "%"])

    if existing != [[0]], do: flunk("seed tenants exist without a completed seed")

    pairs =
      for i <- 1..n do
        name = @tenant_prefix <> String.pad_leading("#{i}", 3, "0")
        {:ok, tenant} = Converger.Tenants.create_tenant(%{name: name})

        {:ok, channel} =
          Converger.Channels.create_channel(%{
            name: "p100m",
            type: "websocket",
            mode: "outbound",
            status: "active",
            tenant_id: tenant.id
          })

        {Ecto.UUID.dump!(tenant.id), Ecto.UUID.dump!(channel.id)}
      end

    Enum.unzip(pairs)
  end

  defp seed_conversations(tenants, channels, s, first_month, last_seq) do
    Repo.query!(
      """
      INSERT INTO conversations (id, tenant_id, channel_id, status, metadata, inserted_at, updated_at, last_seq)
      SELECT md5('c' || t || ':' || c)::uuid, ($1::uuid[])[t + 1], ($2::uuid[])[t + 1], 'active', '{}'::jsonb,
             $3::timestamp, $3::timestamp, $4::bigint
      FROM generate_series(0, $5::int - 1) AS t, generate_series(0, $6::int - 1) AS c
      """,
      [
        tenants,
        channels,
        NaiveDateTime.new!(first_month, ~T[00:00:00]),
        last_seq,
        s.tenants,
        s.conversations_per_tenant
      ],
      timeout: :infinity
    )
  end

  # Activity number gg (1-based, global over all months) belongs to tenant
  # gg % T and conversation (gg / T) % C of that tenant, with seq
  # gg / (T * C) + 1: unique per conversation. Ids are md5-derived so a
  # delivery can name its activity without a join.
  @activity_insert """
  INSERT INTO %LEAF% (id, tenant_id, conversation_id, type, sender, text, attachments, metadata,
                      idempotency_key, inserted_at, updated_at, seq, source_channel_id)
  SELECT md5('a' || x.gg)::uuid,
         ($1::uuid[])[(x.gg % $9)::int + 1],
         md5('c' || (x.gg % $9) || ':' || ((x.gg / $9) % $10))::uuid,
         'message',
         CASE WHEN x.gg % 2 = 0 THEN 'user' ELSE 'bot' END,
         left(repeat(md5(x.gg::text), 10), 20 + (x.gg % 280)::int),
         '[]'::jsonb,
         jsonb_build_object('source', 'p100m', 'n', x.gg % 100),
         CASE WHEN x.gg % 2 = 0 THEN 'idem-' || x.gg END,
         x.ts, x.ts,
         x.gg / ($9 * $10) + 1,
         ($2::uuid[])[(x.gg % $9)::int + 1]
  FROM (SELECT $6::bigint + g AS gg,
               $3::timestamp + ((g - 1) * $4::float8 / $5::bigint) * interval '1 second' AS ts
        FROM generate_series($7::bigint, $8::bigint) AS g) AS x
  """

  # Delivery d of a month belongs to activity ((d - 1) * A / D) + 1 of the
  # same month: one delivery per activity for D of its A activities.
  @delivery_insert """
  INSERT INTO %LEAF% (id, activity_id, channel_id, status, attempts, last_error, delivered_at,
                      metadata, inserted_at, updated_at, sent_at, read_at, provider_message_id,
                      retry_count, tenant_id, activity_inserted_at)
  SELECT md5('d' || y.gg)::uuid,
         md5('a' || y.gg)::uuid,
         ($2::uuid[])[(y.gg % $9)::int + 1],
         CASE WHEN y.gg % 50 = 0 THEN 'failed' WHEN y.gg % 5 = 0 THEN 'read' ELSE 'delivered' END,
         CASE WHEN y.gg % 50 = 0 THEN 5 ELSE 1 END,
         CASE WHEN y.gg % 50 = 0 THEN 'provider returned 503' END,
         CASE WHEN y.gg % 50 = 0 THEN NULL ELSE y.ts + interval '1 second' END,
         '{}'::jsonb,
         y.ts, y.ts + interval '1 second',
         y.ts + interval '200 milliseconds',
         CASE WHEN y.gg % 5 = 0 THEN y.ts + interval '30 seconds' END,
         'pm-' || y.gg,
         0,
         ($1::uuid[])[(y.gg % $9)::int + 1],
         y.ts
  FROM (SELECT $6::bigint + x.g AS gg,
               $3::timestamp + ((x.g - 1) * $4::float8 / $5::bigint) * interval '1 second' AS ts
        FROM (SELECT ((d - 1) * $5::bigint / $10::bigint) + 1 AS g
              FROM generate_series($7::bigint, $8::bigint) AS d) AS x) AS y
  """

  # Identifiers are partition names built by Converger.Partitions.
  defp seed_partition({table, month, a_m, d_m, off}, ctx) do
    leaf = Partitions.leaf_name(table, month)
    from = NaiveDateTime.new!(month, ~T[00:00:00])
    to = NaiveDateTime.new!(Partitions.next_month(month), ~T[00:00:00])
    span = NaiveDateTime.diff(to, from) * 1.0
    total = if table == "activities", do: a_m, else: d_m

    sql =
      String.replace(
        if(table == "activities", do: @activity_insert, else: @delivery_insert),
        "%LEAF%",
        leaf
      )

    started = System.monotonic_time()

    Repo.query!(
      "CREATE TABLE #{leaf} (LIKE #{table} INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE)"
    )

    starts = if total == 0, do: [], else: Enum.to_list(1..total//ctx.batch)

    for lo <- starts do
      hi = min(lo + ctx.batch - 1, total)
      # $10 is the conversations per tenant for activities and the month's
      # delivery count for deliveries.
      last = if table == "activities", do: ctx.c, else: d_m
      params = [ctx.tenants, ctx.channels, from, span, a_m, off, lo, hi, ctx.t, last]

      {:ok, _} =
        Repo.transaction(
          fn ->
            Repo.query!("SET LOCAL synchronous_commit = off")
            Repo.query!(sql, params, timeout: :infinity)
          end,
          timeout: :infinity
        )
    end

    loaded_ms = ms_since(started)
    index_partition(table, leaf)
    Repo.query!("VACUUM (ANALYZE) #{leaf}", [], timeout: :infinity)
    attach(table, leaf, from, to)

    log(
      "  #{leaf}: #{total} rows, insert #{Float.round(loaded_ms / 1000, 1)} s, " <>
        "total #{Float.round(ms_since(started) / 1000, 1)} s"
    )
  end

  # The per-partition unique indexes, then every index of the parent that
  # the partition does not have yet (same definition), so ATTACH only
  # matches existing indexes instead of building them under its lock.
  defp index_partition(table, leaf) do
    Enum.each(
      Partitions.leaf_index_statements(table, leaf),
      &Repo.query!(&1, [], timeout: :infinity)
    )

    %{rows: parent} =
      Repo.query!(
        """
        SELECT pg_get_indexdef(i.indexrelid), c.contype::text, pg_get_constraintdef(c.oid)
        FROM pg_index i
        LEFT JOIN pg_constraint c ON c.conindid = i.indexrelid AND c.conrelid = i.indrelid
        WHERE i.indrelid = $1::text::regclass
        """,
        [table]
      )

    for [def, contype, condef] <- parent do
      cond do
        contype == "p" ->
          Repo.query!("ALTER TABLE #{leaf} ADD CONSTRAINT #{leaf}_pkey #{condef}", [],
            timeout: :infinity
          )

        contype in ["u", "x"] ->
          Repo.query!("ALTER TABLE #{leaf} ADD #{condef}", [], timeout: :infinity)

        index_body(def) in leaf_index_bodies(leaf) ->
          :ok

        true ->
          unique = if String.starts_with?(def, "CREATE UNIQUE "), do: "UNIQUE ", else: ""
          name = "#{leaf}_p100m_#{:erlang.phash2(def)}"

          Repo.query!("CREATE #{unique}INDEX #{name} ON #{leaf} #{index_body(def)}", [],
            timeout: :infinity
          )
      end
    end
  end

  defp index_body(def),
    do: def |> String.split(" USING ", parts: 2) |> List.last() |> then(&("USING " <> &1))

  defp leaf_index_bodies(leaf) do
    %{rows: rows} =
      Repo.query!(
        "SELECT pg_get_indexdef(indexrelid) FROM pg_index WHERE indrelid = $1::text::regclass",
        [leaf]
      )

    Enum.map(rows, fn [def] -> index_body(def) end)
  end

  # A validated CHECK constraint matching the range lets ATTACH skip its scan.
  defp attach(table, leaf, from, to) do
    key = Partitions.partition_key(table)

    Repo.query!(
      "ALTER TABLE #{leaf} ADD CONSTRAINT #{leaf}_p100m_range CHECK (#{key} IS NOT NULL AND " <>
        "#{key} >= '#{from}' AND #{key} < '#{to}')",
      [],
      timeout: :infinity
    )

    Repo.query!(
      "ALTER TABLE #{table} ATTACH PARTITION #{leaf} FOR VALUES FROM ('#{from}') TO ('#{to}')",
      [],
      timeout: :infinity
    )

    Repo.query!("ALTER TABLE #{leaf} DROP CONSTRAINT #{leaf}_p100m_range")
  end

  ## Sizes and counts

  defp sizes(months) do
    by_month =
      for month <- months do
        Map.new(Partitions.tables(), fn table ->
          leaf = Partitions.leaf_name(table, month)

          %{rows: [[heap, idx, total, est]]} =
            Repo.query!(
              "SELECT pg_relation_size($1::text::regclass), pg_indexes_size($1::text::regclass), " <>
                "pg_total_relation_size($1::text::regclass), reltuples::bigint FROM pg_class WHERE oid = $1::text::regclass",
              [leaf]
            )

          {table, %{heap_bytes: heap, index_bytes: idx, total_bytes: total, rows_estimate: est}}
        end)
        |> Map.put(:month, Partitions.month_label(month))
      end

    totals =
      for table <- Partitions.tables(), into: %{} do
        {table,
         %{
           heap_bytes: by_month |> Enum.map(& &1[table].heap_bytes) |> Enum.sum(),
           index_bytes: by_month |> Enum.map(& &1[table].index_bytes) |> Enum.sum(),
           total_bytes: by_month |> Enum.map(& &1[table].total_bytes) |> Enum.sum()
         }}
      end

    %{rows: [[db_bytes]]} = Repo.query!("SELECT pg_database_size(current_database())")

    %{
      by_month: by_month,
      by_table: totals,
      total_bytes: totals |> Map.values() |> Enum.map(& &1.total_bytes) |> Enum.sum(),
      # From the statistics (the seed analyzes every partition).
      rows: for(m <- by_month, t <- Partitions.tables(), do: m[t].rows_estimate) |> Enum.sum(),
      database_bytes: db_bytes
    }
  end

  defp counts_by_tenant(month) do
    for table <- Partitions.tables(), reduce: %{} do
      acc ->
        %{rows: rows} =
          Repo.query!(
            "SELECT tenant_id, count(*) FROM #{Partitions.leaf_name(table, month)} GROUP BY 1",
            [],
            timeout: :infinity
          )

        Enum.reduce(rows, acc, fn [tenant, n], acc ->
          Map.put(acc, {table, Ecto.UUID.load!(tenant)}, n)
        end)
    end
  end

  defp rows_by_table(counts) do
    Enum.reduce(counts, %{}, fn {{table, _}, n}, acc -> Map.update(acc, table, n, &(&1 + n)) end)
  end

  defp table_exists?(table, month),
    do: Partitions.table_exists?(Partitions.leaf_name(table, month))

  ## Archive storage

  defp storage_config(s) do
    [
      endpoint: s.minio_endpoint,
      path_style: true,
      region: "us-east-1",
      bucket: @bucket,
      access_key_id: System.get_env("P100M_MINIO_ACCESS_KEY", "minioadmin"),
      secret_access_key: System.get_env("P100M_MINIO_SECRET_KEY", "minioadmin")
    ]
  end

  defp configure_archive(s) do
    config = storage_config(s)
    url = "#{config[:endpoint]}/#{config[:bucket]}"

    headers =
      SigV4.sign_headers("PUT", url, [], "",
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        region: config[:region]
      )

    %{status: status} = Req.put!(url, headers: headers, body: "", retry: false)
    assert status in [200, 409], "could not create the MinIO bucket (HTTP #{status})"

    Application.put_env(:converger, Converger.Archive,
      storage: S3Storage,
      storage_opts: config,
      prefix: "archive",
      part_rows: s.part_rows
    )

    # Production default (config/test.exs turns it off for the SQL sandbox).
    partitions = Application.get_env(:converger, Converger.Partitions, [])

    Application.put_env(
      :converger,
      Converger.Partitions,
      Keyword.put(partitions, :detach_concurrently, true)
    )
  end

  defp archive_summary(month, events) do
    parts = Archive.parts(month)
    part_events = for {:part, _at, rows, bytes} <- events, do: {rows, bytes}

    %{
      parts: length(parts),
      objects_bytes: parts |> Enum.map(& &1.byte_size) |> Enum.sum(),
      rows: parts |> Enum.map(& &1.row_count) |> Enum.sum(),
      by_table:
        parts
        |> Enum.group_by(& &1.table_name)
        |> Map.new(fn {t, ps} ->
          {t,
           %{
             parts: length(ps),
             rows: ps |> Enum.map(& &1.row_count) |> Enum.sum(),
             bytes: ps |> Enum.map(& &1.byte_size) |> Enum.sum()
           }}
        end),
      all_verified: Enum.all?(parts, &(&1.verified_at != nil)),
      uploaded_parts_seen: length(part_events),
      part_rows: Archive.part_rows()
    }
  end

  defp read_back(month, before) do
    started = System.monotonic_time()
    parts = Archive.parts(month)

    results =
      parts
      |> Task.async_stream(
        fn part ->
          {:ok, body} = Archive.storage().get(Archive.storage_opts(), part.object_key)
          lines = body |> :zlib.gunzip() |> :binary.matches("\n") |> length()

          %{
            key: {part.table_name, part.tenant_id},
            lines: lines,
            bytes: byte_size(body),
            sha_ok: Archive.sha256(body) == part.sha256,
            lines_ok: lines == part.row_count
          }
        end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, r} -> r end)

    archived =
      Enum.reduce(results, %{}, fn r, acc -> Map.update(acc, r.key, r.lines, &(&1 + r.lines)) end)

    mismatches =
      for key <- Enum.uniq(Map.keys(before) ++ Map.keys(archived)),
          Map.get(before, key, 0) != Map.get(archived, key, 0) do
        {table, tenant} = key

        %{
          table: table,
          tenant_id: tenant,
          partition: Map.get(before, key, 0),
          archive: Map.get(archived, key, 0)
        }
      end

    %{
      seconds: Float.round(ms_since(started) / 1000, 1),
      objects: length(results),
      bytes: results |> Enum.map(& &1.bytes) |> Enum.sum(),
      rows: results |> Enum.map(& &1.lines) |> Enum.sum(),
      checksums_ok: Enum.all?(results, & &1.sha_ok) and Enum.all?(results, & &1.lines_ok),
      counts_match: mismatches == [],
      mismatches: mismatches
    }
  end

  defp reimport(_month, _before, 0), do: %{tenants: []}

  defp reimport(month, before, n) do
    tenants =
      before |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort() |> Enum.take(n)

    results =
      for tenant <- tenants do
        log("re-importing tenant #{tenant} #{Partitions.month_label(month)}")
        started = System.monotonic_time()
        {:ok, stats} = Archive.import_tenant_month(tenant, month)
        seconds = ms_since(started) / 1000

        in_db =
          Map.new(Partitions.tables(), fn table ->
            %{rows: [[c]]} =
              Repo.query!(
                "SELECT count(*) FROM #{Partitions.leaf_name(table, month)} WHERE tenant_id = $1",
                [Ecto.UUID.dump!(tenant)],
                timeout: :infinity
              )

            {table, c}
          end)

        rows = stats |> Map.values() |> Enum.map(& &1.rows) |> Enum.sum()

        %{
          tenant_id: tenant,
          seconds: Float.round(seconds, 1),
          rows_per_second: round(rows / max(seconds, 0.001)),
          stats: stats,
          in_database: in_db,
          counts_match:
            Enum.all?(Partitions.tables(), fn t ->
              expected = Map.get(before, {t, tenant}, 0)
              in_db[t] == expected and get_in(stats, [t, :inserted]) == expected
            end)
        }
      end

    # Leave the database as the retention run left it.
    for table <- Partitions.tables() do
      :ok = Partitions.detach(table, month, concurrently: false)
      :ok = Partitions.drop_detached(table, month)
    end

    %{tenants: results}
  end

  ## Writers

  defp writer_fixture do
    {:ok, tenant} =
      Converger.Tenants.create_tenant(%{
        name: "p100m-writers-#{System.unique_integer([:positive])}"
      })

    {:ok, channel} =
      Converger.Channels.create_channel(%{
        name: "writers",
        type: "websocket",
        mode: "outbound",
        status: "active",
        tenant_id: tenant.id
      })

    %{tenant: tenant, channel: channel}
  end

  # Inserts activities at `rate` per second through the normal code path
  # and returns [{started_ms_since_t0, latency_us, :ok | :error}].
  defp start_writer(ctx, i, rate, t0, parent) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      {:ok, conversation} =
        Converger.Conversations.create_conversation(%{
          tenant_id: ctx.tenant.id,
          channel_id: ctx.channel.id,
          status: "active"
        })

      send(parent, {:writer_ready, i})
      interval_us = div(1_000_000, max(rate, 1))
      write_loop(ctx, conversation, t0, interval_us, System.monotonic_time(), [])
    end)
  end

  defp write_loop(ctx, conversation, t0, interval_us, next, acc) do
    receive do
      :stop -> acc
    after
      0 ->
        started = System.monotonic_time()

        outcome =
          try do
            case Activities.create_activity(%{
                   tenant_id: ctx.tenant.id,
                   conversation_id: conversation.id,
                   sender: "p100m",
                   text: "live"
                 }) do
              {:ok, _} -> :ok
              _ -> :error
            end
          rescue
            _ -> :error
          end

        finished = System.monotonic_time()
        latency = System.convert_time_unit(finished - started, :native, :microsecond)
        at = System.convert_time_unit(started - t0, :native, :millisecond)
        next = next + System.convert_time_unit(interval_us, :microsecond, :native)
        wait = System.convert_time_unit(next - finished, :native, :millisecond)
        # Behind schedule: continue at once, but do not burst to catch up.
        next = if wait < 0, do: finished, else: next
        if wait > 0, do: Process.sleep(wait)
        write_loop(ctx, conversation, t0, interval_us, next, [{at, latency, outcome} | acc])
    end
  end

  defp stop_writers(tasks) do
    Enum.flat_map(tasks, fn task ->
      send(task.pid, :stop)
      Task.await(task, 120_000)
    end)
  end

  defp writer_stats(samples, op_start, op_end, phases, baseline_s) do
    # Skip the first 2 s (connection warm-up) of the baseline.
    warm = 2_000
    window = fn from, to -> Enum.filter(samples, fn {at, _, _} -> at >= from and at < to end) end
    grace = 500

    %{
      baseline: stats(window.(min(warm, baseline_s * 1000), op_start)),
      during: stats(window.(op_start, op_end + grace)),
      detach:
        stats(
          window.(phases.detach_start_ms || op_start, (phases.detach_end_ms || op_start) + grace)
        ),
      drop:
        stats(window.(phases.drop_start_ms || op_end, (phases.drop_end_ms || op_end) + grace)),
      after: stats(window.(op_end + grace, :infinity)),
      errors: Enum.count(samples, fn {_, _, o} -> o == :error end)
    }
  end

  defp stats([]), do: %{count: 0, p50_ms: nil, p99_ms: nil, max_ms: nil}

  defp stats(samples) do
    sorted = samples |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    n = length(sorted)
    pct = fn p -> Float.round(Enum.at(sorted, min(n - 1, trunc(n * p))) / 1000, 2) end

    %{
      count: n,
      p50_ms: pct.(0.5),
      p99_ms: pct.(0.99),
      max_ms: Float.round(List.last(sorted) / 1000, 2),
      errors: Enum.count(samples, fn {_, _, o} -> o == :error end)
    }
  end

  ## Telemetry

  @doc false
  def handle_event([:converger, :repo, :query], measurements, metadata, parent) do
    query = metadata[:query] || ""

    kind =
      cond do
        String.contains?(query, "DETACH PARTITION") -> :detach
        String.starts_with?(query, "DROP TABLE") -> :drop
        true -> nil
      end

    if kind do
      send(
        parent,
        {:p100m_ddl, kind, query, System.monotonic_time(), measurements[:total_time] || 0}
      )
    end
  end

  def handle_event([:converger, :archive, :part], measurements, _metadata, parent) do
    send(parent, {:p100m_part, System.monotonic_time(), measurements.rows, measurements.bytes})
  end

  defp drain_events(t0, acc \\ []) do
    receive do
      {:p100m_ddl, kind, query, at, total} ->
        finished = System.convert_time_unit(at - t0, :native, :millisecond)
        took = System.convert_time_unit(total, :native, :microsecond) / 1000
        drain_events(t0, [{kind, query, finished - took, finished, took} | acc])

      {:p100m_part, at, rows, bytes} ->
        drain_events(t0, [
          {:part, System.convert_time_unit(at - t0, :native, :millisecond), rows, bytes} | acc
        ])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp phases(events, op_start, op_end) do
    detaches = for {:detach, q, s, e, took} <- events, s >= op_start - 1, do: {q, s, e, took}

    drops =
      for {:drop, q, s, e, took} <- events,
          s >= op_start - 1,
          e <= op_end + 1,
          do: {q, s, e, took}

    span = fn list ->
      {list |> Enum.map(&elem(&1, 1)) |> Enum.min(fn -> nil end),
       list |> Enum.map(&elem(&1, 2)) |> Enum.max(fn -> nil end)}
    end

    {ds, de} = span.(detaches)
    {xs, xe} = span.(drops)
    detach_ms = detaches |> Enum.map(&elem(&1, 3)) |> Enum.sum()
    drop_ms = drops |> Enum.map(&elem(&1, 3)) |> Enum.sum()

    # Retention exports, verifies and drops one table after the other, so a
    # table's export + verification runs from the previous step's end to
    # its own DROP TABLE.
    {per_table, _} =
      drops
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map_reduce(de || op_start, fn {q, s, e, _}, prev ->
        table = q |> String.replace_prefix("DROP TABLE ", "") |> String.split("_p") |> hd()
        {{table, round(s - prev)}, e}
      end)

    %{
      archive_ms_by_table: Map.new(per_table),
      detach_ms: Float.round(detach_ms * 1.0, 1),
      drop_ms: Float.round(drop_ms * 1.0, 1),
      detach_statements:
        Enum.map(detaches, fn {q, _, _, t} -> %{query: q, ms: Float.round(t * 1.0, 1)} end),
      drop_statements:
        Enum.map(drops, fn {q, _, _, t} -> %{query: q, ms: Float.round(t * 1.0, 1)} end),
      # Export + read back + verification: between the last detach and the
      # first drop, minus the first table's drop between the two exports.
      archive_and_verify_ms: op_end - op_start - round(detach_ms) - round(drop_ms),
      detach_start_ms: ds && round(ds),
      detach_end_ms: de,
      drop_start_ms: xs && round(xs),
      drop_end_ms: xe
    }
  end

  ## Postgres

  defp pg_version do
    %{rows: [[v]]} = Repo.query!("SHOW server_version")
    v
  end

  defp postgres_info do
    settings =
      ~w(server_version shared_buffers effective_cache_size maintenance_work_mem work_mem
         max_wal_size checkpoint_timeout synchronous_commit wal_level wal_compression full_page_writes)

    Map.new(settings, fn name ->
      %{rows: [[v]]} = Repo.query!("SHOW #{name}")
      {name, v}
    end)
  end

  defp wal_lsn do
    %{rows: [[lsn]]} = Repo.query!("SELECT pg_current_wal_lsn()::text")
    lsn
  end

  defp wal_diff(later, earlier) do
    %{rows: [[n]]} =
      Repo.query!("SELECT pg_wal_lsn_diff($1::text::pg_lsn, $2::text::pg_lsn)::bigint", [
        later,
        earlier
      ])

    n
  end

  ## Projection to 100M rows

  defp projection(r) do
    target = 100_000_000
    seeded = r.settings.rows
    # Rows present before this run (fewer than seeded on a reused database).
    rows = r.sizes.rows
    oldest = r.oldest_month.rows
    target_oldest = target * oldest / max(rows, 1)
    bytes_per_row = r.sizes.total_bytes / max(rows, 1)
    archive_bytes_per_row = r.archive.objects_bytes / max(oldest, 1)
    seed_s = r.seed["seconds"] || 0
    archive_s = r.operation.archive_and_verify_ms / 1000
    # Data + one max_wal_size of WAL + the archive objects of one month, with 20% headroom.
    max_wal = parse_size(r.postgres["max_wal_size"])
    disk = (bytes_per_row * target + max_wal + archive_bytes_per_row * target_oldest) * 1.2

    %{
      target_rows: target,
      bytes_per_row: Float.round(bytes_per_row, 1),
      archive_bytes_per_row: Float.round(archive_bytes_per_row, 1),
      database_bytes: round(bytes_per_row * target),
      oldest_month_rows: round(target_oldest),
      archive_bytes: round(archive_bytes_per_row * target_oldest),
      disk_bytes_needed: round(disk),
      seed_seconds: round(seed_s * target / max(seeded, 1)),
      archive_and_verify_seconds: round(archive_s * target_oldest / max(oldest, 1)),
      note:
        "Linear extrapolation from this run; index builds and I/O do not scale linearly once data exceeds RAM"
    }
  end

  defp parse_size(v) do
    case Regex.run(~r/^(\d+)\s*(kB|MB|GB|TB)?$/, v || "") do
      [_, n, unit] ->
        String.to_integer(n) *
          %{"kB" => 1024, "MB" => 1024 ** 2, "GB" => 1024 ** 3, "TB" => 1024 ** 4}[unit]

      [_, n] ->
        String.to_integer(n)

      _ ->
        0
    end
  end

  ## Output

  defp hardware(nil), do: %{}

  defp hardware(path) do
    case File.read(path) do
      {:ok, body} -> Jason.decode!(body)
      _ -> %{}
    end
  end

  defp report(r) do
    w = r.writers
    op = r.operation
    a = r.archive
    p = r.projection

    """
    # Partition archive and drop: #{r.settings.rows} rows (issue #192)

    Generated #{r.generated_at} by `test/load/partition_100m/run.sh`.

    ## Hardware

    #{hardware_table(r.hardware, r.postgres)}

    ## Dataset

    #{r.seed["activities"]} activities + #{r.seed["deliveries"]} deliveries, #{r.settings.months} months, #{r.settings.tenants} tenants. Seed: #{r.seed["seconds"]} s (#{r.seed["rows_per_second"]} rows/s, #{r.seed["seed_jobs"]} jobs), WAL #{fmt_bytes(r.seed["wal_bytes"])}#{reused_note(r.seed)}.

    | Table | Heap | Indexes | Total |
    | --- | --- | --- | --- |
    #{Enum.map_join(r.sizes.by_table, "\n", fn {t, b} -> "| #{t} | #{fmt_bytes(b.heap_bytes)} | #{fmt_bytes(b.index_bytes)} | #{fmt_bytes(b.total_bytes)} |" end)}

    Database #{fmt_bytes(r.sizes.database_bytes)}; #{p.bytes_per_row} bytes per row (tables + indexes).

    ## Oldest month #{r.oldest_month.month}

    #{r.oldest_month.rows_by_table["activities"]} activities + #{r.oldest_month.rows_by_table["deliveries"]} deliveries, archived by `Converger.Retention.run/1` to MinIO.

    | Step | Result |
    | --- | --- |
    | `DETACH PARTITION ... CONCURRENTLY` (both tables) | #{op.detach_ms} ms |
    | Export + read back + verify | #{Float.round(op.archive_and_verify_ms / 1000, 1)} s (#{Enum.map_join(op.archive_ms_by_table, ", ", fn {t, ms} -> "#{t} #{Float.round(ms / 1000, 1)} s" end)}) |
    | `DROP TABLE` (both tables) | #{op.drop_ms} ms |
    | Whole run | #{Float.round(op.total_ms / 1000, 1)} s |
    | WAL during the run (writers included) | #{fmt_bytes(op.wal_bytes)} |
    | Archive | #{a.parts} objects, #{fmt_bytes(a.objects_bytes)} (#{p.archive_bytes_per_row} bytes per row), #{a.rows} rows, all verified: #{a.all_verified} |
    | Partition gone afterwards | #{not r.oldest_month.still_exists} |

    ## Writers (#{r.settings.writers} x #{r.settings.writer_rate}/s, `Activities.create_activity/2`)

    | Window | Inserts | p50 ms | p99 ms | max ms |
    | --- | --- | --- | --- | --- |
    #{writer_row("before (baseline)", w.baseline)}
    #{writer_row("during the whole run", w.during)}
    #{writer_row("during the detach", w.detach)}
    #{writer_row("during the drop", w.drop)}
    #{writer_row("after", w.after)}

    Failed inserts: #{w.errors}.

    ## Read back

    #{readback_text(r.readback)}

    #{reimport_section(r.reimport.tenants)}

    ## Projection to #{p.target_rows} rows

    Disk needed about #{fmt_bytes(p.disk_bytes_needed)} (#{fmt_bytes(p.database_bytes)} data, one max_wal_size, #{fmt_bytes(p.archive_bytes)} archive, +20%); seed about #{fmt_duration(p.seed_seconds)}; archive and verify of the oldest month (#{p.oldest_month_rows} rows) about #{fmt_duration(p.archive_and_verify_seconds)}. #{p.note}.
    """
  end

  defp hardware_table(hw, pg) do
    get = fn key -> Map.get(hw, key) || "?" end

    """
    | | |
    | --- | --- |
    | Host | #{get.("host_os")}, #{fmt_bytes(hw["host_memory_bytes"])} memory |
    | CPU | #{String.trim(get.("host_cpu"))} |
    | Docker | #{get.("docker_os")}, #{get.("docker_cpus")} CPUs, #{fmt_bytes(hw["docker_memory_bytes"])} memory, server #{get.("docker_version")} |
    | Docker disk | #{fmt_bytes(hw["disk_total_bytes"])} total, #{fmt_bytes(hw["disk_avail_bytes"])} free before the run |
    | Postgres | #{pg["server_version"]}, shared_buffers #{pg["shared_buffers"]}, max_wal_size #{pg["max_wal_size"]}, synchronous_commit #{pg["synchronous_commit"]} |\
    """
  end

  defp reused_note(%{"reused" => true}), do: " (reused from an earlier run)"
  defp reused_note(_), do: ""

  defp writer_row(name, st),
    do: "| #{name} | #{st.count} | #{dash(st.p50_ms)} | #{dash(st.p99_ms)} | #{dash(st.max_ms)} |"

  defp dash(nil), do: "-"
  defp dash(v), do: v

  defp readback_text(rb) do
    checksums = if rb.checksums_ok, do: "match", else: "**do not match**"
    counts = if rb.counts_match, do: "equal", else: "**differ from**"

    "#{rb.objects} objects (#{fmt_bytes(rb.bytes)}) downloaded in #{rb.seconds} s: SHA-256 and line " <>
      "counts #{checksums} the manifest; per tenant and table, archived rows #{counts} the rows " <>
      "counted in the partition before the detach (#{rb.rows} rows)."
  end

  defp reimport_section([]), do: "Re-import skipped."

  defp reimport_section(tenants) do
    lines =
      Enum.map_join(tenants, "\n", fn t ->
        match = if t.counts_match, do: "yes", else: "**no**"

        "| `#{t.tenant_id}` | #{t.in_database["activities"]} / #{t.in_database["deliveries"]} " <>
          "| #{t.seconds} s (#{t.rows_per_second} rows/s) | #{match} |"
      end)

    """
    Re-import (`Converger.Archive.import_tenant_month/2`):

    | Tenant | Rows in DB (activities / deliveries) | Time | Counts match |
    | --- | --- | --- | --- |
    #{lines}\
    """
  end

  defp fmt_bytes(nil), do: "?"

  defp fmt_bytes(b) when is_number(b) do
    cond do
      b >= 1024 ** 3 -> "#{Float.round(b / 1024 ** 3, 2)} GiB"
      b >= 1024 ** 2 -> "#{Float.round(b / 1024 ** 2, 1)} MiB"
      b >= 1024 -> "#{Float.round(b / 1024, 1)} KiB"
      true -> "#{b} B"
    end
  end

  defp fmt_duration(s) when s >= 3600, do: "#{Float.round(s / 3600, 1)} h"
  defp fmt_duration(s) when s >= 60, do: "#{Float.round(s / 60, 1)} min"
  defp fmt_duration(s), do: "#{s} s"

  defp now_ms(t0),
    do: System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)

  defp ms_since(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) / 1000

  defp log(msg),
    do: IO.puts("[p100m #{NaiveDateTime.local_now() |> NaiveDateTime.to_time()}] #{msg}")
end
