defmodule Converger.Channels.Mqtt.Publisher do
  @moduledoc """
  The connection an `mqtt` channel publishes with on this node (activities
  to `topic_out`, dead letters to `topic_dlq`): a
  `Converger.Channels.Mqtt.Connection` with a clean session and a client id
  of its own per node, started on first use under
  `Converger.Channels.Broker.Publishers`, replaced when the channel's config
  changes and stopped after `:publisher_idle_ms` without publishes.
  Publishes of one channel are serialised through it.
  """

  alias Converger.Channels.Adapters.Mqtt
  alias Converger.Channels.Broker.Publishers
  alias Converger.Channels.Mqtt.Connection

  def child_spec(channel) do
    %{
      id: {__MODULE__, channel.id},
      start: {__MODULE__, :start_link, [channel]},
      restart: :temporary
    }
  end

  @doc "Start the publishing connection of `channel`."
  def start_link(channel) do
    with {:ok, options} <- Mqtt.connection_options(channel, :publisher) do
      Connection.start_link(
        options ++ [name: Publishers.via(channel), idle_ms: Publishers.idle_ms()]
      )
    end
  end

  @doc """
  Publish `payload` to `topic` with `qos`; QoS 1 waits for the `PUBACK`
  (`opts[:timeout]`, default 10 s). Returns `:ok` or `{:error, reason}`.
  """
  @spec publish(map(), String.t(), binary(), 0 | 1, keyword()) :: :ok | {:error, term()}
  def publish(channel, topic, payload, qos, opts \\ []) do
    if Converger.Channels.Mqtt.Packet.valid_topic?(topic) do
      with {:ok, pid} <- Publishers.ensure(__MODULE__, channel) do
        Connection.publish(pid, topic, payload, qos, opts)
      end
    else
      {:error, {:invalid_topic, topic}}
    end
  end
end
