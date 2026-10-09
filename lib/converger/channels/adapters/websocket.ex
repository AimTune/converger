defmodule Converger.Channels.Adapters.WebSocket do
  @moduledoc """
  Delivers activities to the WebSocket clients of a `websocket` channel
  (end-user widgets, agent consoles).

  `deliver_activity/2` broadcasts the canonical activity, after the channel's
  middleware, on two PubSub topics:

    * `channel:<channel id>` - sockets that follow the whole channel (an agent
      console joined to `converger:channel:<channel id>`);
    * `channel:<channel id>:conversation:<conversation id>` - sockets of the
      channel that joined that one conversation.

  It returns the number of connected clients (joined sockets of the channel
  that follow the conversation, see `ConvergerWeb.Sockets.count_connections/2`).
  With at least one, the delivery is marked `sent`. With none, or when the
  channel's config has `require_ack: true`, the delivery stays `pending`:
  activities are persisted, so the client catches up by replay when it
  resumes, and the delivery is marked `sent` once a client has replayed or
  acknowledged it (`Converger.Deliveries.acknowledge/3`).

  Messages sent by clients arrive over the socket and go through
  `Converger.Inbound`, like inbound webhooks of other channel types.
  """

  @behaviour Converger.Channels.Adapter

  alias Converger.Activities.Serializer

  @impl true
  def supported_modes, do: ~w(inbound outbound duplex)

  @impl true
  def capabilities, do: [:inbound, :outbound]

  @impl true
  def validate_config(config) do
    if Map.get(config, "require_ack", Map.get(config, :require_ack)) in [
         nil,
         "",
         true,
         false,
         "true",
         "false"
       ],
       do: :ok,
       else: {:error, "websocket config require_ack must be true or false"}
  end

  @impl true
  def deliver_activity(channel, activity) do
    payload = Serializer.canonical(activity)

    ConvergerWeb.Endpoint.broadcast!(channel_topic(channel.id), "new_activity", payload)

    ConvergerWeb.Endpoint.broadcast!(
      conversation_topic(channel.id, activity.conversation_id),
      "new_activity",
      payload
    )

    clients = ConvergerWeb.Sockets.count_connections(channel.id, activity.conversation_id)
    meta = %{connected_clients: clients}

    if clients > 0 and not require_ack?(channel),
      do: {:ok, meta},
      else: {:pending, meta}
  end

  @impl true
  def parse_inbound(_channel, _params) do
    {:error, "websocket channels receive messages over the WebSocket, not inbound webhooks"}
  end

  @doc "PubSub topic of every delivery to the channel."
  def channel_topic(channel_id), do: "channel:#{channel_id}"

  @doc "PubSub topic of the channel's deliveries in one conversation."
  def conversation_topic(channel_id, conversation_id),
    do: "channel:#{channel_id}:conversation:#{conversation_id}"

  @doc "Whether deliveries stay `pending` until a client acknowledges them."
  def require_ack?(%{config: config}) when is_map(config),
    do: Map.get(config, "require_ack", Map.get(config, :require_ack)) in [true, "true"]

  def require_ack?(_channel), do: false
end
