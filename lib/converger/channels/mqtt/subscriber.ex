defmodule Converger.Channels.Mqtt.Subscriber do
  @moduledoc """
  The consumer of an `mqtt` channel (`c:Converger.Channels.Broker.consumer_child_spec/1`),
  run once in the cluster by `Converger.Channels.Consumers`.

  It opens a `Converger.Channels.Mqtt.Connection` in a persistent session
  (`clean_session: false`) subscribed to `topic_in`, and handles the
  messages one at a time, in arrival order, with
  `Converger.Channels.Broker.handle/4` (envelope, idempotency key,
  `Converger.Inbound`, retries, dead-lettering). A QoS 1 message is
  acknowledged after it was accepted or dead-lettered, never before: if the
  subscriber stops first, the broker delivers it again to the next
  subscriber of the session, where its idempotency key makes it a
  duplicate.

  The connection is linked: when it closes (broker restart, network
  failure, missed keepalive) the subscriber stops and the consumer
  supervisor starts a new one, which resumes the session. Keepalive pings
  run in the connection process, so a slow message does not drop the
  connection.
  """

  use GenServer

  require Logger

  alias Converger.Channels.Adapters.Mqtt
  alias Converger.Channels.Broker
  alias Converger.Channels.Mqtt.Connection

  def child_spec(channel) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [channel]},
      # Finish the message in hand on shutdown (its retries are bounded by
      # the broker_channels settings); after that it is redelivered.
      shutdown: 30_000
    }
  end

  def start_link(channel), do: GenServer.start_link(__MODULE__, channel)

  @impl true
  def init(channel) do
    Process.flag(:trap_exit, true)

    with {:ok, options} <- Mqtt.connection_options(channel, :subscriber),
         {:ok, conn} <- Connection.start_link(options) do
      Logger.info("MQTT subscriber connected",
        channel_id: channel.id,
        source: (channel.config || %{})["topic_in"]
      )

      {:ok, %{channel: channel, conn: conn}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:mqtt_publish, conn, packet}, %{conn: conn, channel: channel} = state) do
    info = Mqtt.packet_info(channel, packet)
    _outcome = Broker.handle(channel, Mqtt, info)
    if packet.qos == 1, do: Connection.ack(conn, packet.packet_id)
    {:noreply, state}
  end

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) do
    Logger.warning("MQTT subscriber connection closed",
      channel_id: state.channel.id,
      reason: inspect(reason)
    )

    {:stop, reason_for(reason), %{state | conn: nil}}
  end

  # The consumer supervisor stops us.
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when is_pid(conn) do
    Connection.stop(conn)
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp reason_for(:normal), do: {:shutdown, :connection_closed}
  defp reason_for(reason), do: reason
end
