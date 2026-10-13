defmodule Converger.Channels.Discord.GatewayWorker do
  @moduledoc """
  Turns the messages a `Converger.Channels.Discord.Gateway` connection
  receives into activities, one at a time and in order, with
  `Converger.Channels.Broker.handle_message/5` (`Converger.Inbound`,
  in-place retries of transient failures). Running beside the connection
  keeps the Gateway heartbeat on time while a message is being stored or
  retried. Linked to the connection: one stops, the other stops too.
  """

  use GenServer

  alias Converger.Channels.Adapters.Discord
  alias Converger.Channels.Broker

  def start_link(channel), do: GenServer.start_link(__MODULE__, channel)

  @doc "Queue `message` (a parsed `MESSAGE_CREATE`) for processing."
  def process(worker, message, source), do: GenServer.cast(worker, {:message, message, source})

  @impl true
  def init(channel), do: {:ok, channel}

  @impl true
  def handle_cast({:message, message, source}, channel) do
    info = %{
      payload: "",
      message_id: get_in(message, ["metadata", "discord_message_id"]),
      source: source
    }

    _outcome = Broker.handle_message(channel, Discord, message, info)
    {:noreply, channel}
  end
end
