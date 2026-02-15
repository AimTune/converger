defmodule Converger.PerformanceTest do
  # We don't use ChannelCase here because we want to run this as a script
  # but we'll need the helpers.

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  alias ConvergerWeb.UserSocket
  alias ConvergerWeb.ConversationChannel
  alias Converger.Repo
  import Phoenix.ChannelTest

  @endpoint ConvergerWeb.Endpoint

  def run(opts \\ []) do
    connections = Keyword.get(opts, :connections, 100)
    messages = Keyword.get(opts, :messages, 5)
    live = Keyword.get(opts, :live, false)
    concurrency = Keyword.get(opts, :max_concurrency, 50)

    unless live do
      # 1. Setup Sandbox for the main process
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      case Ecto.Adapters.SQL.Sandbox.checkout(Repo) do
        {:ok, _} -> :ok
        {:error, {:already_checked_out, _}} -> :ok
        other -> IO.puts("Warning: Checkout returned #{inspect(other)}")
      end

      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    end

    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    IO.puts("--- Load Test Configuration ---")
    IO.puts("Environment: #{if live, do: "LIVE (No Sandbox)", else: "Sandbox"}")
    IO.puts("Simulated Concurrency: #{connections}")
    IO.puts("Worker Concurrency: #{concurrency}")
    IO.puts("Messages/Session: #{messages}")
    IO.puts("Total Messages: #{connections * messages}")
    IO.puts("-------------------------------")

    start_time = System.monotonic_time()

    1..connections
    |> Task.async_stream(
      fn i ->
        for m <- 1..messages do
          # Simulate Activity creation with idempotency key
          Converger.Activities.create_activity(%{
            "tenant_id" => tenant.id,
            "conversation_id" => conversation.id,
            "text" => "load-msg-#{i}-#{m}",
            "sender" => "user",
            "idempotency_key" => "load-#{if live, do: "live", else: "sb"}-#{i}-#{m}"
          })
        end

        :ok
      end,
      max_concurrency: concurrency,
      timeout: 60_000
    )
    |> Enum.to_list()

    end_time = System.monotonic_time()
    duration_ms = System.convert_time_unit(end_time - start_time, :native, :millisecond)

    IO.puts("--- Results ---")
    IO.puts("Duration: #{duration_ms}ms")
    success_count = connections * messages
    IO.puts("Throughput: #{Float.round(success_count / (duration_ms / 1000), 2)} msgs/sec")
    IO.puts("---------------")
  end
end
