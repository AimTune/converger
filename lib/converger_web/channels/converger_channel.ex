defmodule ConvergerWeb.ConvergerChannel do
  @moduledoc """
  Channel of the Converger API socket (`/socket/converger`).

  ## Topics

    * `converger:conversation:<conversation id>` - one conversation. Allowed
      for a token restricted to that conversation, or a channel-level token of
      either the conversation's own channel (**owned**) or a `websocket`
      channel that an enabled routing rule targets from the conversation's
      channel (**routed**). An owned socket receives every activity of the
      conversation as it is committed (the `conversation:<id>` broadcast). A
      routed socket receives what the pipeline delivers to its channel, after
      that channel's middleware
      (`Converger.Channels.Adapters.WebSocket.conversation_topic/2`).
    * `converger:channel:<channel id>` - every delivery to a `websocket`
      channel, across conversations (an agent console). Requires a token with
      `scope: "channel"` for that channel. Frames carry `conversation_id`.

  Every live and replayed activity is pushed as an `activitySet` frame. On a
  conversation topic the socket tracks the last `seq` it pushed: a frame at or
  below it is dropped (replay overlap, the same activity on two topics) and a
  frame above `last + 1` first pushes the missing range from the database
  (PubSub is at-most-once across nodes, and deliveries run concurrently).

  ## Client events

    * `new_activity` - send a message. It goes through `Converger.Inbound`, so
      the socket's channel must be `inbound` or `duplex`. Reply: `{id, seq}`.
      On a channel topic the payload names its `conversation_id`.
    * `ack` `{watermark}` - the client has received everything up to the
      watermark (a `seq` or a watermark string); marks the channel's pending
      deliveries `sent` (`Converger.Deliveries.acknowledge/3`). Reply:
      `{acknowledged}`. On a channel topic the payload names its `conversation_id`.

  Unless the channel requires acks (`require_ack: true` in its config), a
  replay also marks the replayed activities' deliveries `sent`.
  """

  use ConvergerWeb, :channel

  require Logger

  alias Converger.{Activities, Channels, Conversations, Deliveries, Inbound, RoutingRules}
  alias Converger.Channels.Adapters.WebSocket
  alias Converger.ConvergerAPI.Watermark
  alias Converger.Pagination
  alias Converger.Pipeline.Middleware
  alias ConvergerWeb.ConvergerAPI.ActivityJSON

  # Client idempotency keys are opaque strings of bounded size.
  @max_idempotency_key_bytes 255

  @impl true
  def join("converger:conversation:" <> conversation_id, payload, socket) do
    claims = socket.assigns.converger_claims

    with {:ok, channel} <- Channels.get_active_channel(claims["channel_id"], claims["tenant_id"]),
         {:ok, source, conversation} <- conversation_access(conversation_id, channel, claims) do
      # The head is read before subscribing: anything committed later arrives
      # live or is pushed by gap detection.
      socket =
        assign(socket,
          channel: channel,
          conversation_id: conversation.id,
          source: source,
          last_seq: conversation.last_seq
        )

      # Queued before subscribing, so every live frame is handled after the
      # replay and dropped when the replay already covered it.
      send(self(), {:after_join, payload["watermark"]})
      ConvergerWeb.Endpoint.subscribe(live_topic(socket))
      {:ok, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def join("converger:channel:" <> channel_id, _payload, socket) do
    claims = socket.assigns.converger_claims

    with %{"scope" => "channel", "channel_id" => ^channel_id} <- claims,
         {:ok, %{type: "websocket"} = channel} <-
           Channels.get_active_channel(channel_id, claims["tenant_id"]) do
      send(self(), :after_join)
      ConvergerWeb.Endpoint.subscribe(WebSocket.channel_topic(channel_id))
      {:ok, assign(socket, channel: channel, conversation_id: nil, source: :channel)}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "invalid_topic"}}

  @impl true
  def handle_in("new_activity", payload, socket) when is_map(payload) do
    # Only client fields are taken from the payload; the sender is the
    # authenticated token subject, never client-supplied. `idempotency_key`
    # (optional) makes a re-send safe; it is stored namespaced by the sender.
    with {:ok, conversation_id} <- target_conversation(socket, payload),
         {:ok, key} <- idempotency_key(payload) do
      sender = sender(socket.assigns.converger_claims)

      message = %{
        "type" => payload["type"] || "message",
        "text" => payload["text"],
        "attachments" => payload["attachments"] || [],
        "metadata" => payload["channelData"] || payload["metadata"] || %{},
        "sender" => sender,
        "idempotency_key" => key && "ws:#{sender}:#{key}"
      }

      socket.assigns.channel
      |> Inbound.receive_message(message, conversation_id: conversation_id)
      |> reply_to_send(socket)
    else
      {:error, reply} -> {:reply, {:error, reply}, socket}
    end
  end

  def handle_in("ack", %{"watermark" => watermark} = payload, socket) do
    %{channel: channel} = socket.assigns

    with {:ok, conversation_id} <- ack_conversation(socket, payload),
         {:ok, seq} <- ack_seq(watermark) do
      count =
        if channel.type == "websocket",
          do: Deliveries.acknowledge(channel.id, conversation_id, seq),
          else: 0

      {:reply, {:ok, %{acknowledged: count}}, socket}
    else
      _ -> {:reply, {:error, %{reason: "invalid_ack"}}, socket}
    end
  end

  # A malformed known event or an unknown event: answered, the channel stays joined.
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "bad_request"}}, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    channel = socket.assigns.channel

    ConvergerWeb.Sockets.track(socket, channel.id, %{
      tenant_id: channel.tenant_id,
      scope: "channel"
    })

    {:noreply, socket}
  end

  def handle_info({:after_join, watermark}, socket) do
    %{channel: channel, conversation_id: conversation_id} = socket.assigns

    ConvergerWeb.Sockets.track(socket, channel.id, %{
      tenant_id: channel.tenant_id,
      conversation_id: conversation_id
    })

    # Without a watermark the client starts live (no replay) from the current
    # head. Replay is capped at :ws_replay_limit activities (the oldest ones
    # after the watermark); when `has_more` is true the client fetches the
    # rest over GET /api/v1/converger/conversations/:id/activities?watermark=<frame watermark>
    # until `has_more` is false.
    socket =
      case Watermark.decode(watermark) do
        {:ok, {_, _} = position} -> replay(socket, position)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "new_activity", payload: payload},
        %{assigns: %{source: :channel}} = socket
      ) do
    push(socket, "activitySet", %{
      conversation_id: payload.conversation_id,
      activities: [ActivityJSON.activity_data(payload)],
      watermark: Watermark.encode(payload.seq),
      has_more: false
    })

    {:noreply, socket}
  end

  # Live activity of the joined conversation (owned: committed; routed:
  # delivered to the socket's channel).
  def handle_info(%Phoenix.Socket.Broadcast{event: "new_activity", payload: payload}, socket) do
    {:noreply, push_live(socket, payload)}
  end

  # Delivery status broadcasts (delivered with #25).
  def handle_info(%Phoenix.Socket.Broadcast{event: "delivery_status"}, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Authorization ---

  # {:ok, :owned | :routed, conversation} when the token may follow the conversation.
  defp conversation_access(conversation_id, channel, claims) do
    restricted = claims["conversation_id"]

    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         true <- is_nil(restricted) or restricted == conversation_id,
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, channel.tenant_id) do
      cond do
        conversation.channel_id == channel.id ->
          {:ok, :owned, conversation}

        channel.type == "websocket" and
            RoutingRules.routes_to?(conversation.channel_id, channel.id, channel.tenant_id) ->
          {:ok, :routed, conversation}

        # A token issued for this one conversation.
        is_binary(restricted) ->
          {:ok, :owned, conversation}

        true ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp live_topic(%{assigns: %{source: :owned, conversation_id: conversation_id}}),
    do: "conversation:#{conversation_id}"

  defp live_topic(%{assigns: %{source: :routed, channel: channel, conversation_id: id}}),
    do: WebSocket.conversation_topic(channel.id, id)

  # --- Pushing activities ---

  defp push_live(%{assigns: %{last_seq: last}} = socket, %{seq: seq} = payload) do
    cond do
      seq == last + 1 ->
        push(socket, "activitySet", %{
          activities: [ActivityJSON.activity_data(payload)],
          watermark: Watermark.encode(seq),
          has_more: false
        })

        assign(socket, :last_seq, seq)

      # Already pushed: replay overlap or a duplicate broadcast.
      seq <= last ->
        socket

      # A gap: push the missing range (which includes this activity) from the database.
      true ->
        replay(socket, {:seq, last})
    end
  end

  defp replay(socket, position) do
    {activities, has_more} =
      Activities.page_activities_since(socket.assigns.conversation_id, position,
        limit: Pagination.config(:ws_replay_limit)
      )

    push_activities(socket, activities, has_more)
  end

  # One activitySet for activities read from the database (in seq order).
  defp push_activities(socket, [], _has_more), do: socket

  defp push_activities(socket, activities, has_more) do
    last_seq = List.last(activities).seq

    case Enum.flat_map(activities, &frame(socket, &1)) do
      [] ->
        :ok

      frames ->
        push(socket, "activitySet", %{
          activities: frames,
          watermark: Watermark.encode(last_seq),
          has_more: has_more
        })
    end

    acknowledge_replayed(socket, last_seq)
    assign(socket, :last_seq, last_seq)
  end

  # A routed socket sees activities as delivered to its channel: the
  # channel's middleware applies (a halted activity is not pushed).
  defp frame(%{assigns: %{source: :routed, channel: channel}}, activity) do
    case Middleware.run(activity, channel) do
      {:ok, transformed} -> [ActivityJSON.activity_data(transformed)]
      {:halt, _reason} -> []
    end
  end

  defp frame(_socket, activity), do: [ActivityJSON.activity_data(activity)]

  defp acknowledge_replayed(%{assigns: %{channel: channel, conversation_id: id}}, seq) do
    if channel.type == "websocket" and not WebSocket.require_ack?(channel),
      do: Deliveries.acknowledge(channel.id, id, seq)
  end

  # --- Client events ---

  defp target_conversation(%{assigns: %{source: :channel}} = socket, payload) do
    %{channel: channel, converger_claims: claims} = socket.assigns

    case conversation_access(payload["conversation_id"], channel, claims) do
      {:ok, _source, conversation} -> {:ok, conversation.id}
      :error -> {:error, %{reason: "unauthorized"}}
    end
  end

  defp target_conversation(socket, _payload), do: {:ok, socket.assigns.conversation_id}

  defp ack_conversation(%{assigns: %{source: :channel}}, payload) do
    Ecto.UUID.cast(payload["conversation_id"])
  end

  defp ack_conversation(socket, _payload), do: {:ok, socket.assigns.conversation_id}

  defp ack_seq(seq) when is_integer(seq) and seq >= 0, do: {:ok, seq}

  defp ack_seq(watermark) when is_binary(watermark) do
    case Integer.parse(watermark) do
      {seq, ""} when seq >= 0 ->
        {:ok, seq}

      _ ->
        case Watermark.decode(watermark) do
          {:ok, {:seq, seq}} -> {:ok, seq}
          _ -> :error
        end
    end
  end

  defp ack_seq(_watermark), do: :error

  defp sender(claims), do: claims["user_id"] || claims["sub"]

  defp idempotency_key(%{"idempotency_key" => nil}), do: {:ok, nil}

  defp idempotency_key(%{"idempotency_key" => key})
       when is_binary(key) and key != "" and byte_size(key) <= @max_idempotency_key_bytes,
       do: {:ok, key}

  defp idempotency_key(%{"idempotency_key" => _}) do
    {:error,
     %{
       reason: "invalid_activity",
       errors: %{
         idempotency_key: [
           "must be a non-empty string of at most #{@max_idempotency_key_bytes} bytes"
         ]
       }
     }}
  end

  defp idempotency_key(_payload), do: {:ok, nil}

  # The reply carries the stored activity's id and seq (also for a
  # duplicate), so the client can correlate its send with the live frame.
  defp reply_to_send(result, socket) do
    case result do
      {tag, activity} when tag in [:created, :duplicate] ->
        {:reply, {:ok, %{id: activity.id, seq: activity.seq}}, socket}

      {:rejected, changeset} ->
        {:reply, {:error, %{reason: "invalid_activity", errors: errors(changeset)}}, socket}

      {:error, reason}
      when reason in [:conversation_closed, :inbound_not_supported, :not_found] ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}

      {:error, reason} ->
        Logger.warning("WebSocket send failed",
          channel_id: socket.assigns.channel.id,
          error: inspect(reason)
        )

        {:reply, {:error, %{reason: "unavailable"}}, socket}
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
      end)
    end)
  end
end
