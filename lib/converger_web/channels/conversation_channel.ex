defmodule ConvergerWeb.ConversationChannel do
  use ConvergerWeb, :channel

  require Logger

  alias Converger.{Activities, Conversations, Channels}

  @impl true
  def join("conversation:" <> conversation_id, payload, socket) do
    claims = socket.assigns[:claims] || %{}

    cond do
      not authorized?(conversation_id, claims) ->
        Logger.warning("WebSocket channel join unauthorized",
          conversation_id: conversation_id,
          claims: claims
        )

        {:error, %{reason: "unauthorized"}}

      # Sockets of a deactivated channel are disconnected; don't let them rejoin.
      not channel_active?(conversation_id, claims["tenant_id"]) ->
        {:error, %{reason: "channel_inactive"}}

      true ->
        send(self(), {:after_join, payload})
        {:ok, socket}
    end
  end

  defp channel_active?(conversation_id, tenant_id) do
    with %Conversations.Conversation{channel_id: channel_id} <-
           Conversations.get_conversation(conversation_id, tenant_id),
         {:ok, _channel} <- Channels.get_active_channel(channel_id, tenant_id) do
      true
    else
      _ -> false
    end
  end

  # Client idempotency keys are opaque strings of bounded size.
  @max_idempotency_key_bytes 255

  @impl true
  def handle_in("new_activity", payload, socket) when is_map(payload) do
    claims = socket.assigns.claims

    # Only client fields are taken from the payload; the sender is the
    # authenticated token subject, never client-supplied.
    #
    # `idempotency_key` (optional, like the REST `x-idempotency-key` header)
    # makes a re-push safe: a client that lost the connection before the
    # reply re-sends with the same key and gets the already stored activity
    # instead of a duplicate. The key is stored namespaced by the sender
    # (`ws:<sub>:<key>`), so a WebSocket client cannot claim a key that the
    # tenant's REST API, an inbound webhook or another participant uses in
    # the same conversation.
    sender = claims["sub"] || "user"

    case idempotency_key(payload) do
      {:ok, idempotency_key} ->
        system_attrs = %{
          tenant_id: claims["tenant_id"],
          conversation_id: claims["conversation_id"],
          sender: sender,
          idempotency_key: idempotency_key && "ws:#{sender}:#{idempotency_key}"
        }

        # The pipeline (run by create_activity) is the only delivery path: it
        # applies middleware, tracks deliveries, retries and fans out via routing rules.
        payload
        |> Activities.create_client_activity(system_attrs)
        |> reply_to_push(socket)

      {:error, message} ->
        {:reply, {:error, %{reason: "invalid_activity", errors: %{idempotency_key: [message]}}},
         socket}
    end
  end

  def handle_in("new_activity", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_activity"}}, socket}
  end

  defp idempotency_key(%{"idempotency_key" => nil}), do: {:ok, nil}

  defp idempotency_key(%{"idempotency_key" => key})
       when is_binary(key) and key != "" and byte_size(key) <= @max_idempotency_key_bytes,
       do: {:ok, key}

  defp idempotency_key(%{"idempotency_key" => _}),
    do: {:error, "must be a non-empty string of at most #{@max_idempotency_key_bytes} bytes"}

  defp idempotency_key(_payload), do: {:ok, nil}

  # The reply carries the stored activity's id and seq (also on an idempotent
  # replay), so the client can correlate its push with the broadcast.
  defp reply_to_push(result, socket) do
    case result do
      {:ok, activity} ->
        {:reply, {:ok, %{id: activity.id, seq: activity.seq}}, socket}

      {:error, :conversation_closed} ->
        {:reply, {:error, %{reason: "conversation_closed"}}, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, {:error, %{reason: "invalid_activity", errors: errors(changeset)}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "invalid_activity"}}, socket}
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
      end)
    end)
  end

  @impl true
  def handle_info({:after_join, payload}, socket) do
    conversation_id = socket.assigns.claims["conversation_id"]

    conversation = Conversations.get_conversation!(conversation_id)
    channel = Channels.get_channel!(conversation.channel_id)

    socket =
      socket
      |> assign(:channel_type, channel.type)
      |> assign(:channel, channel)

    ConvergerWeb.Sockets.track(socket, channel.id, %{
      tenant_id: conversation.tenant_id,
      conversation_id: conversation_id
    })

    Logger.info("WebSocket channel joined",
      conversation_id: conversation_id,
      tenant_id: conversation.tenant_id
    )

    if last_id = payload["last_activity_id"] do
      # Replay is capped at :ws_replay_limit activities. When more are
      # pending, a `replay_truncated` event carries the id of the last
      # replayed activity; the client rejoins with it as `last_activity_id`
      # to continue.
      {activities, has_more} =
        Activities.page_activities_since(conversation_id, {:activity_id, last_id},
          limit: Converger.Pagination.config(:ws_replay_limit)
        )

      Enum.each(activities, fn activity ->
        # Same payload as the live `new_activity` broadcast.
        push(socket, "new_activity", Converger.Activities.Serializer.canonical(activity))
      end)

      if has_more do
        push(socket, "replay_truncated", %{
          has_more: true,
          last_activity_id: List.last(activities).id
        })
      end
    end

    {:noreply, socket}
  end

  defp authorized?(conversation_id, %{"conversation_id" => claim_cid}) do
    conversation_id == claim_cid
  end

  defp authorized?(_, _), do: false
end
