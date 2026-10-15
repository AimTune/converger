defmodule Converger.Backbone.NatsConformanceTest do
  @moduledoc """
  The backbone conformance suite against NATS JetStream (issue #66).
  Excluded by default, like the broker channel suites:

      docker run -d --name nats -p 4222:4222 nats:2.10 -js
      NATS_URL=nats://localhost:4222 mix test --only nats
  """

  use ExUnit.Case, async: false

  @moduletag :nats
  @moduletag timeout: 600_000

  use Converger.BackboneConformance, backbone: Converger.Backbone.Nats, timeout: 60_000

  import Converger.BackboneBrokerCase

  setup_all do
    start_backbone(Converger.Backbone.Nats,
      servers: System.get_env("NATS_URL", "nats://localhost:4222"),
      # Unacknowledged messages of a killed consumer come back after 3 s.
      ack_wait_seconds: 3,
      max_age_seconds: 3_600
    )
  end

  setup do
    await_connected()
    %{run: run_id()}
  end

  defp await_connected(tries \\ 100) do
    case Converger.Backbone.Nats.Connection.conn() do
      {:ok, _} ->
        :ok

      {:error, _} when tries > 0 ->
        Process.sleep(100)
        await_connected(tries - 1)

      {:error, reason} ->
        flunk("NATS backbone not connected: #{inspect(reason)}")
    end
  end

  def deliver(_context), do: :ok

  def crash_consumers(_context, subscription), do: kill_consumers(subscription)
end
