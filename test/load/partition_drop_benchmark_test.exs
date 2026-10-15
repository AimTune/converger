defmodule Converger.PartitionDropBenchmarkTest do
  @moduledoc """
  Benchmark (issue #30): dropping a month of activities and deliveries while
  writers keep inserting activities, compared with a `DELETE` of the same
  number of rows.

  Excluded by default; run with

      mix test test/load/partition_drop_benchmark_test.exs --include benchmark

  `BENCH_ROWS` (default 200,000) rows per table and month, `BENCH_WRITERS`
  (default 8) concurrent writers. Runs outside the SQL sandbox (real commits,
  real `DETACH PARTITION ... CONCURRENTLY`) on two far-past months and
  removes everything it created.
  """
  use ExUnit.Case, async: false

  alias Converger.{Activities, Partitions, Repo}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :benchmark
  @moduletag timeout: :infinity

  @drop_month ~D[2001-01-01]
  @delete_month ~D[2001-02-01]
  # Budgets: the detach + drop is metadata work; the writers must never wait
  # on it for more than a fraction of a second.
  @drop_budget_ms 2_000
  @writer_stall_budget_ms 1_000

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

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
      :ok = Sandbox.checkout(Repo, sandbox: false)

      for table <- Partitions.tables(), month <- [@drop_month, @delete_month] do
        Partitions.detach(table, month, concurrently: false)
        Partitions.drop_detached(table, month)
      end

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

  defp seed_month(month, rows, ctx) do
    for table <- Partitions.tables(), do: {:ok, _} = Partitions.create_partition(table, month)

    {:ok, conversation} =
      Converger.Conversations.create_conversation(%{
        tenant_id: ctx.tenant.id,
        channel_id: ctx.channel.id,
        status: "active"
      })

    from = NaiveDateTime.new!(month, ~T[00:00:00])

    Repo.query!(
      """
      INSERT INTO activities (id, tenant_id, conversation_id, type, sender, text, metadata,
                              inserted_at, updated_at, seq)
      SELECT gen_random_uuid(), $1, $2, 'message', 'bench', repeat('x', 200), '{}'::jsonb,
             $3::timestamp + (g * interval '1 second'), now(), g
      FROM generate_series(1, $4) AS g
      """,
      [Ecto.UUID.dump!(ctx.tenant.id), Ecto.UUID.dump!(conversation.id), from, rows],
      timeout: :infinity
    )

    Repo.query!(
      """
      INSERT INTO deliveries (id, activity_id, channel_id, status, inserted_at, updated_at,
                              tenant_id, activity_inserted_at)
      SELECT gen_random_uuid(), a.id, $1, 'sent', a.inserted_at, now(), a.tenant_id, a.inserted_at
      FROM activities a WHERE a.conversation_id = $2
      """,
      [Ecto.UUID.dump!(ctx.channel.id), Ecto.UUID.dump!(conversation.id)],
      timeout: :infinity
    )

    Repo.query!("ANALYZE activities")
    Repo.query!("ANALYZE deliveries")
  end

  # Inserts activities through the normal code path until told to stop and
  # reports every insert's latency in microseconds.
  defp start_writer(ctx, parent) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

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

  defp ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000

  defp timed(fun) do
    started = System.monotonic_time()
    result = fun.()
    {ms(System.monotonic_time() - started), result}
  end

  defp percentile(sorted, p),
    do: Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p)))

  test "dropping a month partition takes milliseconds and does not block writers", ctx do
    rows = env_int("BENCH_ROWS", 200_000)
    writers = env_int("BENCH_WRITERS", 8)

    {seed_ms, _} =
      timed(fn ->
        seed_month(@drop_month, rows, ctx)
        seed_month(@delete_month, rows, ctx)
      end)

    tasks = for _ <- 1..writers, do: start_writer(ctx, self())
    for _ <- 1..writers, do: assert_receive(:writer_ready, 10_000)
    Process.sleep(1_000)

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
    # An insert blocked by the drop would complete just after it.
    grace = System.convert_time_unit(500, :millisecond, :native)
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

    latencies =
      Enum.flat_map(tasks, fn task ->
        send(task.pid, :stop)
        Task.await(task, 60_000)
      end)

    all = latencies |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    during =
      latencies
      |> Enum.filter(fn {at, _} -> at >= window_start and at <= window_end + grace end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort()

    max_during_ms = if during == [], do: 0.0, else: List.last(during) / 1000

    IO.puts("""

    Partition drop benchmark (#{rows} activities + #{rows} deliveries per month, #{writers} writers)
      seed two months:                 #{Float.round(seed_ms / 1000, 1)} s
      DETACH ... CONCURRENTLY (both):  #{Float.round(detach_ms, 1)} ms
      DROP TABLE (both):               #{Float.round(drop_ms, 1)} ms
      DELETE of the same rows:         #{Float.round(delete_ms, 1)} ms
      inserts total / during drop:     #{length(all)} / #{length(during)}
      insert latency p50 / p99 / max:  #{Float.round(percentile(all, 0.5) / 1000, 2)} / #{Float.round(percentile(all, 0.99) / 1000, 2)} / #{Float.round(List.last(all) / 1000, 2)} ms
      max insert latency during drop:  #{Float.round(max_during_ms, 2)} ms
    """)

    assert drop_ms < @drop_budget_ms
    assert max_during_ms < @writer_stall_budget_ms
    assert during != [], "writers made no progress while the partition was dropped"
    refute Partitions.table_exists?(Partitions.leaf_name("activities", @drop_month))
  end
end
