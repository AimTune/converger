defmodule Mix.Tasks.Converger.Loadtest do
  @shortdoc "In-process write-path benchmark of Activities.create_activity/2"

  @moduledoc """
  Measures the activity write path in-process: `Converger.Activities.create_activity/2`
  against the configured database, with no HTTP, WebSocket, adapters or network.
  Useful to see the cost of the per-conversation `seq` lock and the insert on a
  given database; it is **not** a system benchmark. For end-to-end numbers
  (REST -> WebSocket latency, webhook bursts, idle sockets, reconnects) use the
  k6 harness in `load/` (see docs/benchmarks/index.md).

      mix converger.loadtest
      mix converger.loadtest --conversations 50 --messages 200 --concurrency 50

  Options:

    * `--conversations` - conversations written to concurrently (default 100)
    * `--messages` - activities per conversation (default 50)
    * `--concurrency` - concurrent writers (default: one per conversation)
    * `--keep` - keep the tenant and its data (default: deleted afterwards)

  The activities go to a throwaway tenant on an inbound-only channel, so no
  deliveries are enqueued. Run it against a development or scratch database.
  """
  use Mix.Task

  alias Converger.{Activities, Channels, Conversations, Tenants}

  @switches [conversations: :integer, messages: :integer, concurrency: :integer, keep: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    conversations = Keyword.get(opts, :conversations, 100)
    messages = Keyword.get(opts, :messages, 50)
    concurrency = Keyword.get(opts, :concurrency, conversations)

    Mix.Task.run("app.start")

    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    {:ok, tenant} = Tenants.create_tenant(%{name: "loadtest-#{suffix}"})

    try do
      {:ok, channel} =
        Channels.create_channel(%{
          name: "loadtest-#{suffix}",
          tenant_id: tenant.id,
          type: "webhook",
          mode: "inbound",
          # Required by the webhook adapter; never called for an inbound-only channel.
          config: %{"url" => "http://localhost/loadtest"}
        })

      ids =
        for _ <- 1..conversations do
          {:ok, conversation} =
            Conversations.create_conversation(%{tenant_id: tenant.id, channel_id: channel.id})

          conversation.id
        end

      Mix.shell().info(
        "#{conversations} conversations x #{messages} activities, #{concurrency} concurrent writers"
      )

      started = System.monotonic_time()

      latencies =
        ids
        |> Task.async_stream(&write(tenant.id, &1, messages),
          max_concurrency: concurrency,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, latencies} -> latencies end)

      elapsed_ms = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
      report(latencies, elapsed_ms)
    after
      unless opts[:keep], do: Tenants.delete_tenant(tenant)
    end
  end

  defp write(tenant_id, conversation_id, messages) do
    for m <- 1..messages do
      started = System.monotonic_time()

      {:ok, _activity} =
        Activities.create_activity(%{
          "tenant_id" => tenant_id,
          "conversation_id" => conversation_id,
          "type" => "message",
          "text" => "loadtest #{m}",
          "sender" => "loadtest",
          "idempotency_key" => "loadtest-#{conversation_id}-#{m}"
        })

      System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
    end
  end

  defp report(latencies, elapsed_ms) do
    sorted = Enum.sort(latencies)
    count = length(sorted)
    pct = fn p -> Enum.at(sorted, max(0, ceil(p / 100 * count) - 1)) / 1000 end

    Mix.shell().info("""
    activities:  #{count} in #{elapsed_ms} ms
    throughput:  #{Float.round(count / max(elapsed_ms, 1) * 1000, 1)} activities/s
    latency ms:  p50 #{pct.(50)}  p95 #{pct.(95)}  p99 #{pct.(99)}  max #{List.last(sorted) / 1000}
    """)
  end
end
