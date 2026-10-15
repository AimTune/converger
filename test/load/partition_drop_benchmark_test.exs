defmodule Converger.PartitionDropBenchmarkTest do
  @moduledoc """
  Benchmarks (issue #30, epic #59): removing a month of activities and
  deliveries while writers keep inserting activities.

  Excluded by default. Two tests:

    * **drop vs `DELETE`**: `Converger.Partitions` detach and drop of one
      month, compared with a `DELETE` of the same number of rows:

          mix test test/load/partition_drop_benchmark_test.exs --include benchmark --exclude retention_archive

    * **retention with archive**: the whole `Converger.Retention.run/1` path
      on one month (detach concurrently, export every row to storage, read
      every object back and check its size, SHA-256 and the row counts, then
      drop), used for the scaled evidence in
      docs/benchmarks/partition-retention-scaling.md:

          BENCH_ROWS=10000000 BENCH_TEXT_BYTES=16 \\
            mix test test/load/partition_drop_benchmark_test.exs --only retention_archive

  Environment:

    * `BENCH_ROWS` (default 200,000) rows per table and month
    * `BENCH_WRITERS` (default 8) concurrent writers
    * `BENCH_TEXT_BYTES` (default 200) length of each seeded activity text;
      narrow rows keep large runs within the disk
    * `BENCH_BULK_SEED` (`1`/`0`; default `1` above 1,000,000 rows) fill the
      month's tables before building their indexes, see `seed_month/5`
    * `BENCH_ARCHIVE_DIR` where the archive test writes its objects (local
      storage; default a temporary directory). It is removed afterwards.
    * `BENCH_OUT` a file the archive test appends its result to (one JSON line)

  Runs outside the SQL sandbox (real commits, real
  `DETACH PARTITION ... CONCURRENTLY`) on far-past months and removes
  everything it created. Use a dedicated database for large runs
  (`DB_NAME=converger_bench MIX_ENV=test mix do ecto.create, ecto.migrate`).
  """
  use ExUnit.Case, async: false

  alias Converger.{Activities, Archive, Partitions, Repo, Retention}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :benchmark
  @moduletag timeout: :infinity

  @drop_month ~D[2001-01-01]
  @delete_month ~D[2001-02-01]
  @archive_month ~D[2001-03-01]
  @months [@drop_month, @delete_month, @archive_month]
  # Seeded rows are spread over the first 28 days of their month.
  @month_seconds 28 * 24 * 3600
  # Budgets: the detach + drop is metadata work; the writers must never wait
  # on it for more than a fraction of a second.
  @drop_budget_ms 2_000
  @writer_stall_budget_ms 1_000

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)

    {:ok, tenant} =
      Converger.Tenants.create_tenant(%{name: "bench-#{System.unique_integer([:positive])}"})

    {:ok, channel} =
      Converger.Channels.create_channel(%{
        name: "bench",
        type: "websocket",
        mode: "outbound",
        status: "active",
        tenant_id: tenant.id
      })

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)

      for table <- Partitions.tables(), month <- @months do
        Partitions.detach(table, month, concurrently: false)
        Partitions.drop_detached(table, month)
      end

      Repo.query!("DELETE FROM archive_parts WHERE month = ANY($1)", [@months])
      Converger.Workers.PurgeWorker.purge(%{"tenant_id" => tenant.id})
      Repo.delete!(tenant)
    end)

    %{tenant: tenant, channel: channel}
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  defp bulk_seed?(rows) do
    case System.get_env("BENCH_BULK_SEED") do
      nil -> rows > 1_000_000
      value -> value in ["1", "true"]
    end
  end

  # Seeds `rows` activities and one delivery each into `month`.
  #
  # Default: into partitions created by `Partitions.create_partition/2`, so
  # every row maintains every index (as in production). With `bulk: true`
  # (BENCH_BULK_SEED=1, the default above 1,000,000 rows) the leaf tables
  # are filled first and their indexes built afterwards, with the same
  # statements `create_partition/2` runs (`Partitions.leaf_index_statements/2`,
  # then `ATTACH PARTITION`, which builds the parent's indexes on the leaf).
  # The resulting schema is identical; building indexes by sort instead of
  # tens of millions of random UUID inserts makes the seed several times
  # faster, and the indexes come out more compact than in production.
  defp seed_month(month, rows, ctx, text_bytes, bulk) do
    leaf = &Partitions.leaf_name(&1, month)

    if bulk do
      for table <- Partitions.tables() do
        Repo.query!(
          "CREATE TABLE #{leaf.(table)} (LIKE #{table} INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE)"
        )
      end
    else
      for table <- Partitions.tables(), do: {:ok, _} = Partitions.create_partition(table, month)
    end

    {activities, deliveries} =
      if bulk, do: {leaf.("activities"), leaf.("deliveries")}, else: {"activities", "deliveries"}

    {:ok, conversation} =
      Converger.Conversations.create_conversation(%{
        tenant_id: ctx.tenant.id,
        channel_id: ctx.channel.id,
        status: "active"
      })

    from = NaiveDateTime.new!(month, ~T[00:00:00])

    Repo.query!(
      """
      INSERT INTO #{activities} (id, tenant_id, conversation_id, type, sender, text, metadata,
                              inserted_at, updated_at, seq)
      SELECT gen_random_uuid(), $1, $2, 'message', 'bench', repeat('x', $5), '{}'::jsonb,
             $3::timestamp + ((g % $6) * interval '1 second'), now(), g
      FROM generate_series(1, $4) AS g
      """,
      [
        Ecto.UUID.dump!(ctx.tenant.id),
        Ecto.UUID.dump!(conversation.id),
        from,
        rows,
        text_bytes,
        @month_seconds
      ],
      timeout: :infinity
    )

    Repo.query!(
      """
      INSERT INTO #{deliveries} (id, activity_id, channel_id, status, inserted_at, updated_at,
                              tenant_id, activity_inserted_at)
      SELECT gen_random_uuid(), a.id, $1, 'sent', a.inserted_at, now(), a.tenant_id, a.inserted_at
      FROM #{activities} a WHERE a.conversation_id = $2
      """,
      [Ecto.UUID.dump!(ctx.channel.id), Ecto.UUID.dump!(conversation.id)],
      timeout: :infinity
    )

    if bulk do
      Repo.query!("SET maintenance_work_mem = '1GB'")
      to = Partitions.next_month(month)

      for table <- Partitions.tables() do
        for sql <- Partitions.leaf_index_statements(table, leaf.(table)),
            do: Repo.query!(sql, [], timeout: :infinity)

        Repo.query!(
          "ALTER TABLE #{table} ATTACH PARTITION #{leaf.(table)} FOR VALUES FROM ('#{month} 00:00:00') TO ('#{to} 00:00:00')",
          [],
          timeout: :infinity
        )
      end

      Repo.query!("RESET maintenance_work_mem")

      # A month old enough to expire has long been vacuumed and frozen, and
      # the seed's WAL flushed. Without this, autovacuum and the checkpoint
      # after the seed would run during the measurement.
      Repo.query!("VACUUM (FREEZE, ANALYZE) #{activities}", [], timeout: :infinity)
      Repo.query!("VACUUM (FREEZE, ANALYZE) #{deliveries}", [], timeout: :infinity)
      Repo.query!("CHECKPOINT", [], timeout: :infinity)
    else
      Repo.query!("ANALYZE #{activities}", [], timeout: :infinity)
      Repo.query!("ANALYZE #{deliveries}", [], timeout: :infinity)
    end
  end

  # Inserts activities through the normal code path until told to stop and
  # reports every insert's latency in microseconds.
  defp start_writer(ctx, parent) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)

      {:ok, conversation} =
        Converger.Conversations.create_conversation(%{
          tenant_id: ctx.tenant.id,
          channel_id: ctx.channel.id,
          status: "active"
        })

      send(parent, :writer_ready)
      write_loop(ctx, conversation, [])
    end)
  end

  defp write_loop(ctx, conversation, latencies) do
    receive do
      :stop -> latencies
    after
      0 ->
        started = System.monotonic_time()

        {:ok, _} =
          Activities.create_activity(%{
            tenant_id: ctx.tenant.id,
            conversation_id: conversation.id,
            sender: "bench",
            text: "live"
          })

        elapsed =
          System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

        write_loop(ctx, conversation, [{System.monotonic_time(), elapsed} | latencies])
    end
  end

  defp start_writers(ctx, writers) do
    tasks = for _ <- 1..writers, do: start_writer(ctx, self())
    for _ <- 1..writers, do: assert_receive(:writer_ready, 10_000)
    Process.sleep(1_000)
    tasks
  end

  defp stop_writers(tasks) do
    Enum.flat_map(tasks, fn task ->
      send(task.pid, :stop)
      Task.await(task, 60_000)
    end)
  end

  defp ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000

  defp timed(fun) do
    started = System.monotonic_time()
    result = fun.()
    {ms(System.monotonic_time() - started), result}
  end

  defp percentile(sorted, p),
    do: Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p)))

  # Slowest insert (ms) that completed within one of `windows` ({from, to},
  # native) or up to 500 ms after it: an insert blocked by the statement
  # would complete just after it.
  defp max_during(latencies, windows) do
    grace = System.convert_time_unit(500, :millisecond, :native)

    latencies
    |> Enum.filter(fn {at, _} ->
      Enum.any?(windows, fn {from, to} -> at >= from and at <= to + grace end)
    end)
    |> Enum.map(&elem(&1, 1))
    |> case do
      [] -> nil
      during -> Enum.max(during) / 1000
    end
  end

  defp count_during(latencies, windows) do
    grace = System.convert_time_unit(500, :millisecond, :native)

    Enum.count(latencies, fn {at, _} ->
      Enum.any?(windows, fn {from, to} -> at >= from and at <= to + grace end)
    end)
  end

  test "dropping a month partition takes milliseconds and does not block writers", ctx do
    rows = env_int("BENCH_ROWS", 200_000)
    writers = env_int("BENCH_WRITERS", 8)
    text_bytes = env_int("BENCH_TEXT_BYTES", 200)

    {seed_ms, _} =
      timed(fn ->
        seed_month(@drop_month, rows, ctx, text_bytes, bulk_seed?(rows))
        seed_month(@delete_month, rows, ctx, text_bytes, bulk_seed?(rows))
      end)

    tasks = start_writers(ctx, writers)

    window_start = System.monotonic_time()

    {detach_ms, _} =
      timed(fn ->
        for table <- Partitions.tables(),
            do: :ok = Partitions.detach(table, @drop_month, concurrently: true)
      end)

    {drop_ms, _} =
      timed(fn ->
        for table <- Partitions.tables(), do: :ok = Partitions.drop_detached(table, @drop_month)
      end)

    window_end = System.monotonic_time()
    Process.sleep(1_000)

    # For comparison: removing the same amount of data with DELETE.
    {delete_ms, _} =
      timed(fn ->
        from = NaiveDateTime.new!(@delete_month, ~T[00:00:00])
        to = NaiveDateTime.new!(Partitions.next_month(@delete_month), ~T[00:00:00])

        Repo.query!(
          "DELETE FROM deliveries WHERE activity_inserted_at >= $1::timestamp AND activity_inserted_at < $2::timestamp",
          [from, to],
          timeout: :infinity
        )

        Repo.query!(
          "DELETE FROM activities WHERE inserted_at >= $1::timestamp AND inserted_at < $2::timestamp",
          [from, to],
          timeout: :infinity
        )
      end)

    latencies = stop_writers(tasks)
    all = latencies |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    window = [{window_start, window_end}]
    max_during_ms = max_during(latencies, window) || 0.0
    during = count_during(latencies, window)

    IO.puts("""

    Partition drop benchmark (#{rows} activities + #{rows} deliveries per month, #{writers} writers)
      seed two months:                 #{Float.round(seed_ms / 1000, 1)} s
      DETACH ... CONCURRENTLY (both):  #{Float.round(detach_ms, 1)} ms
      DROP TABLE (both):               #{Float.round(drop_ms, 1)} ms
      DELETE of the same rows:         #{Float.round(delete_ms, 1)} ms
      inserts total / during drop:     #{length(all)} / #{during}
      insert latency p50 / p99 / max:  #{Float.round(percentile(all, 0.5) / 1000, 2)} / #{Float.round(percentile(all, 0.99) / 1000, 2)} / #{Float.round(List.last(all) / 1000, 2)} ms
      max insert latency during drop:  #{Float.round(max_during_ms, 2)} ms
    """)

    assert drop_ms < @drop_budget_ms
    assert max_during_ms < @writer_stall_budget_ms
    assert during > 0, "writers made no progress while the partition was dropped"
    refute Partitions.table_exists?(Partitions.leaf_name("activities", @drop_month))
  end

  @tag :retention_archive
  test "retention detaches, archives, verifies and drops a month without blocking writers",
       ctx do
    rows = env_int("BENCH_ROWS", 200_000)
    writers = env_int("BENCH_WRITERS", 8)
    text_bytes = env_int("BENCH_TEXT_BYTES", 200)

    archive_dir =
      System.get_env("BENCH_ARCHIVE_DIR") ||
        Path.join(
          System.tmp_dir!(),
          "converger-archive-bench-#{System.unique_integer([:positive])}"
        )

    # The production settings: concurrent detach (the test config turns it
    # off for the sandbox) and an archive on local storage.
    partitions_env = Application.get_env(:converger, Partitions, [])
    archive_env = Application.get_env(:converger, Archive, [])

    Application.put_env(
      :converger,
      Partitions,
      Keyword.put(partitions_env, :detach_concurrently, true)
    )

    Application.put_env(
      :converger,
      Archive,
      Keyword.merge(archive_env,
        storage: Converger.Uploads.LocalStorage,
        storage_opts: [dir: archive_dir]
      )
    )

    on_exit(fn ->
      Application.put_env(:converger, Partitions, partitions_env)
      Application.put_env(:converger, Archive, archive_env)
      File.rm_rf!(archive_dir)
    end)

    {seed_ms, _} =
      timed(fn -> seed_month(@archive_month, rows, ctx, text_bytes, bulk_seed?(rows)) end)

    sizes =
      Map.new(Partitions.tables(), fn table ->
        %{rows: [[bytes]]} =
          Repo.query!("SELECT pg_total_relation_size(to_regclass($1))", [
            Partitions.leaf_name(table, @archive_month)
          ])

        {table, bytes}
      end)

    # Statement timings from the code path itself: the DETACH and DROP
    # statements (Repo telemetry) and every archived part.
    parent = self()
    handler = "retention-benchmark-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:converger, :repo, :query], [:converger, :archive, :part]],
        &__MODULE__.handle_event/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The writers run alone first: their latency without retention.
    tasks = start_writers(ctx, writers)
    Process.sleep(env_int("BENCH_WRITERS_ALONE_S", 10) * 1000)
    run_start = System.monotonic_time()

    {retention_ms, result} = timed(fn -> Retention.run(months: [@archive_month]) end)

    run_end = System.monotonic_time()
    latencies = stop_writers(tasks)
    :telemetry.detach(handler)

    assert {:ok, [%{action: :partition_dropped, rows: dropped}]} = result

    statements = collect_statements([])
    parts = collect_parts([])

    detach_windows = for {:detach, _q, from, to} <- statements, do: {from, to}

    # DROP TABLE runs in a transaction; the files are unlinked at commit.
    drop_window = fn table ->
      leaf = Partitions.leaf_name(table, @archive_month)

      [from | _] =
        for {:drop, q, from, _to} <- statements, String.contains?(q, leaf), do: from

      [to | _] = for {:commit, _q, s, to} <- statements, s >= from, do: to
      {from, to}
    end

    drop_windows = Enum.map(Partitions.tables(), drop_window)
    detach_ms = detach_windows |> Enum.map(fn {a, b} -> ms(b - a) end) |> Enum.sum()
    drop_ms = drop_windows |> Enum.map(fn {a, b} -> ms(b - a) end) |> Enum.sum()

    drop_statement_ms =
      for({:drop, _q, from, to} <- statements, do: ms(to - from)) |> Enum.sum()

    # Retention runs the tables one after the other: export (the parts),
    # then verify (read every object back), then drop. The export of a table
    # starts when the previous table was dropped (or the detach ended).
    detach_end = detach_windows |> Enum.map(&elem(&1, 1)) |> Enum.max()

    {phases, _} =
      Partitions.tables()
      |> Enum.zip(drop_windows)
      |> Enum.map_reduce(detach_end, fn {table, {drop_start, drop_end}}, from ->
        last_part = for({^table, _n, _b, at} <- parts, do: at) |> Enum.max()

        {%{
           table: table,
           export_ms: Float.round(ms(last_part - from), 1),
           verify_ms: Float.round(ms(drop_start - last_part), 1)
         }, drop_end}
      end)

    export_ms = phases |> Enum.map(& &1.export_ms) |> Enum.sum()
    verify_ms = phases |> Enum.map(& &1.verify_ms) |> Enum.sum()

    manifest = Archive.parts(@archive_month)
    archived = Enum.group_by(manifest, & &1.table_name, & &1.row_count)
    archive_bytes = manifest |> Enum.map(& &1.byte_size) |> Enum.sum()

    # Independent spot check on top of the verification in Retention: a few
    # objects decompressed, their lines counted against the manifest.
    sample = Enum.take_random(manifest, 6)

    sample_ok =
      Enum.all?(sample, fn part ->
        {:ok, body} = Archive.storage().get(Archive.storage_opts(), part.object_key)
        lines = body |> :zlib.gunzip() |> String.split("\n", trim: true) |> length()
        Archive.sha256(body) == part.sha256 and lines == part.row_count
      end)

    all = latencies |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    max_detach = max_during(latencies, detach_windows)
    max_drop = max_during(latencies, drop_windows)
    in_run = for {at, l} <- latencies, at >= run_start and at <= run_end, do: l
    before = for({at, l} <- latencies, at < run_start, do: l) |> Enum.sort()
    in_run = Enum.sort(in_run)
    max_run = Enum.max(in_run, fn -> 0 end) / 1000
    p = fn list, q -> if list == [], do: nil, else: Float.round(percentile(list, q) / 1000, 2) end
    archive_ms = export_ms + verify_ms
    total_rows = Enum.sum(Map.values(dropped))

    summary = %{
      rows_per_table: rows,
      text_bytes: text_bytes,
      writers: writers,
      bulk_seed: bulk_seed?(rows),
      seed_s: Float.round(seed_ms / 1000, 1),
      partition_bytes: sizes,
      detach_ms: Float.round(detach_ms, 1),
      drop_ms: Float.round(drop_ms, 1),
      drop_statement_ms: Float.round(drop_statement_ms, 1),
      drop_commit_ms: Float.round(drop_ms - drop_statement_ms, 1),
      export_s: Float.round(export_ms / 1000, 1),
      verify_s: Float.round(verify_ms / 1000, 1),
      archive_s: Float.round(archive_ms / 1000, 1),
      retention_s: Float.round(retention_ms / 1000, 1),
      archive_rows_per_s: round(total_rows / (archive_ms / 1000)),
      archive_parts: length(manifest),
      archive_bytes: archive_bytes,
      archived_rows: Map.new(archived, fn {t, counts} -> {t, Enum.sum(counts)} end),
      dropped_rows: dropped,
      all_parts_verified: Enum.all?(manifest, & &1.verified_at),
      sample_parts_rechecked: length(sample),
      sample_ok: sample_ok,
      inserts: length(all),
      inserts_during_detach_or_drop: count_during(latencies, detach_windows ++ drop_windows),
      insert_p50_ms: Float.round(percentile(all, 0.5) / 1000, 2),
      insert_p99_ms: Float.round(percentile(all, 0.99) / 1000, 2),
      insert_before_p50_ms: p.(before, 0.5),
      insert_before_p99_ms: p.(before, 0.99),
      insert_during_retention_p50_ms: p.(in_run, 0.5),
      insert_during_retention_p99_ms: p.(in_run, 0.99),
      max_insert_during_detach_ms: max_detach && Float.round(max_detach, 2),
      max_insert_during_drop_ms: max_drop && Float.round(max_drop, 2),
      max_insert_during_retention_ms: Float.round(max_run, 2),
      phases: phases
    }

    if out = System.get_env("BENCH_OUT"),
      do: File.write!(out, Jason.encode!(summary) <> "\n", [:append])

    IO.puts("""

    Retention benchmark (#{rows} activities + #{rows} deliveries in one month, #{writers} writers, text #{text_bytes} B)
      seed:                              #{summary.seed_s} s
      partition size (activities / deliveries): #{div(sizes["activities"], 1_048_576)} / #{div(sizes["deliveries"], 1_048_576)} MiB
      DETACH ... CONCURRENTLY (both):    #{summary.detach_ms} ms
      export (both):                     #{summary.export_s} s
      verify, read back + SHA-256 (both): #{summary.verify_s} s
      DROP TABLE + commit (both):        #{summary.drop_ms} ms (statement #{summary.drop_statement_ms} ms, commit #{summary.drop_commit_ms} ms)
      Retention.run total:               #{summary.retention_s} s
      archive rows/s (export + verify):  #{summary.archive_rows_per_s}
      archive: #{summary.archive_parts} parts, #{Float.round(archive_bytes / 1_048_576, 1)} MiB, rows #{inspect(summary.archived_rows)}
      all parts verified: #{summary.all_parts_verified}, spot check of #{length(sample)} parts: #{sample_ok}
      inserts total / during detach or drop: #{summary.inserts} / #{summary.inserts_during_detach_or_drop}
      insert p50 / p99 before retention: #{inspect(summary.insert_before_p50_ms)} / #{inspect(summary.insert_before_p99_ms)} ms
      insert p50 / p99 during retention: #{inspect(summary.insert_during_retention_p50_ms)} / #{inspect(summary.insert_during_retention_p99_ms)} ms
      slowest insert during detach / drop / whole run: #{inspect(summary.max_insert_during_detach_ms)} / #{inspect(summary.max_insert_during_drop_ms)} / #{summary.max_insert_during_retention_ms} ms
    """)

    assert dropped == %{"activities" => rows, "deliveries" => rows}
    assert summary.archived_rows == dropped
    assert summary.all_parts_verified
    assert sample_ok
    # The detach is metadata work. The drop also unlinks the files at commit,
    # which takes longer with the partition size on some filesystems; what
    # matters is that it does not block the writers (asserted below).
    assert detach_ms < @drop_budget_ms
    assert (max_detach || 0) < @writer_stall_budget_ms
    assert (max_drop || 0) < @writer_stall_budget_ms
    refute Partitions.table_exists?(Partitions.leaf_name("activities", @archive_month))
    refute Partitions.table_exists?(Partitions.leaf_name("deliveries", @archive_month))
  end

  # Telemetry handler of the retention benchmark. Only statements of the
  # test process (the one running Retention) are recorded, not the writers'.
  @doc false
  def handle_event([:converger, :repo, :query], measurements, %{query: query}, parent) do
    kind =
      cond do
        self() != parent -> nil
        query =~ ~r/^ALTER TABLE \S+ DETACH PARTITION/ -> :detach
        String.starts_with?(query, "DROP TABLE") -> :drop
        query == "commit" -> :commit
        true -> nil
      end

    if kind do
      now = System.monotonic_time()
      send(parent, {:statement, kind, query, now - (measurements[:total_time] || 0), now})
    end
  end

  def handle_event([:converger, :archive, :part], %{rows: n, bytes: b}, %{table: table}, parent),
    do: send(parent, {:part, table, n, b, System.monotonic_time()})

  defp collect_statements(acc) do
    receive do
      {:statement, kind, query, from, to} -> collect_statements([{kind, query, from, to} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_parts(acc) do
    receive do
      {:part, table, n, b, at} -> collect_parts([{table, n, b, at} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
