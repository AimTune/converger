defmodule Converger.Channels.Broker.Consumer do
  @moduledoc """
  Supervisor of one channel's consumer, started under
  `Converger.Channels.Consumers`: the Broadway pipeline
  (`Converger.Channels.Broker.Pipeline`) of a Kafka or RabbitMQ channel, or
  the process the adapter names with
  `c:Converger.Channels.Broker.consumer_child_spec/1` (an MQTT subscriber,
  a Discord Gateway connection).

  It is registered globally as `{Converger.Channels.Broker.Consumer,
  channel_id}` (`:global`), so a channel has at most one consumer in the
  cluster: a second start on any node returns `{:error, {:already_started,
  pid}}`. After a network partition heals, `:global` keeps one of two
  clashing consumers and kills the other.

  It is also registered locally in `Converger.Channels.Broker.Registry` under
  `{:consumer, channel_id}` with the fingerprint of the channel
  (`fingerprint/1`), so the consumer manager can tell that a channel's
  config changed and restart it.

  It is `:temporary`: when the consumer keeps crashing (broker unreachable)
  the supervisor gives up, and `Converger.Channels.Consumers.Manager` starts
  it again on its next reconciliation, which spaces out the attempts.
  """

  use Supervisor, restart: :temporary

  alias Converger.Channels.Broker

  def start_link(channel) do
    Supervisor.start_link(__MODULE__, channel, name: global_name(channel.id))
  end

  @doc "The `:global` name of the consumer of `channel_id`."
  def global_name(channel_id), do: {:global, {__MODULE__, channel_id}}

  @doc "The consumer of `channel_id` in the cluster, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(channel_id) do
    case :global.whereis_name({__MODULE__, channel_id}) do
      pid when is_pid(pid) -> pid
      :undefined -> nil
    end
  end

  @doc """
  The fingerprint of what the consumer depends on: type, mode, status,
  tenant and config. A changed fingerprint restarts the consumer.
  """
  @spec fingerprint(map()) :: integer()
  def fingerprint(channel),
    do:
      :erlang.phash2(
        {channel.type, channel.mode, channel.status, channel.tenant_id, channel.config}
      )

  @impl true
  def init(channel) do
    {:ok, _} =
      Registry.register(
        Converger.Channels.Broker.Registry,
        {:consumer, channel.id},
        fingerprint(channel)
      )

    Supervisor.init([Broker.consumer_child_spec(channel)],
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
