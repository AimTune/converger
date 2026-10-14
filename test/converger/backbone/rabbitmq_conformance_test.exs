defmodule Converger.Backbone.RabbitMQConformanceTest do
  @moduledoc """
  The backbone conformance suite against RabbitMQ (issue #66). Excluded by
  default, like the broker channel suites:

      docker run -d --name rabbitmq -p 5672:5672 rabbitmq:3.13-management
      RABBITMQ_URL=amqp://localhost:5672 mix test --only rabbitmq
  """

  use ExUnit.Case, async: false

  @moduletag :rabbitmq
  @moduletag timeout: 600_000

  use Converger.BackboneConformance, backbone: Converger.Backbone.RabbitMQ, timeout: 60_000

  import Converger.BackboneBrokerCase

  setup_all do
    start_backbone(Converger.Backbone.RabbitMQ,
      url: System.get_env("RABBITMQ_URL", "amqp://localhost:5672")
    )
  end

  setup do
    await_connected()
    %{run: run_id()}
  end

  # The connection declares the exchange once it is up.
  defp await_connected(tries \\ 100) do
    case :sys.get_state(Converger.Backbone.RabbitMQ.Connection) do
      %{chan: chan} when not is_nil(chan) ->
        :ok

      _ when tries > 0 ->
        Process.sleep(100)
        await_connected(tries - 1)

      _ ->
        flunk("RabbitMQ backbone not connected")
    end
  end

  def deliver(_context), do: :ok

  def crash_consumers(_context, subscription), do: kill_consumers(subscription)
end
