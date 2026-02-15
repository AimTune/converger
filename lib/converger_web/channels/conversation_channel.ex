defmodule ConvergerWeb.ConversationChannel do
  use ConvergerWeb, :channel

  alias Converger.Activities

  @impl true
  def join("conversation:" <> conversation_id, payload, socket) do
    claims = socket.assigns[:claims] || %{}

    if authorized?(conversation_id, claims) do
      # Fetch channel type to handle echo logic
      conversation = Converger.Conversations.get_conversation!(conversation_id)
      channel = Converger.Channels.get_channel!(conversation.channel_id)

      socket = assign(socket, :channel_type, channel.type)

      require Logger

      Logger.info("WebSocket channel joined",
        conversation_id: conversation_id,
        tenant_id: conversation.tenant_id
      )

      send(self(), {:after_join, payload})
      {:ok, socket}
    else
      require Logger

      Logger.warning("WebSocket channel join unauthorized",
        conversation_id: conversation_id,
        claims: claims
      )

      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("new_activity", payload, socket) do
    tenant_id = socket.assigns.claims["tenant_id"]
    conversation_id = socket.assigns.claims["conversation_id"]

    activity_params =
      payload
      |> Map.put("tenant_id", tenant_id)
      |> Map.put("conversation_id", conversation_id)
      |> Map.put_new("sender", "user")

    case Activities.create_activity(activity_params) do
      {:ok, _activity} ->
        # If echo channel, send the same message back as 'bot'
        if socket.assigns[:channel_type] == "echo" do
          Activities.create_activity(%{
            "tenant_id" => tenant_id,
            "conversation_id" => conversation_id,
            "text" => payload["text"],
            "sender" => "bot"
          })
        end

        {:reply, :ok, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "invalid_activity"}}, socket}
    end
  end

  @impl true
  def handle_info({:after_join, payload}, socket) do
    # Reconnection logic: send missed activities
    if last_id = payload["last_activity_id"] do
      "conversation:" <> conversation_id = socket.topic
      activities = Activities.list_activities_after(conversation_id, last_id)

      Enum.each(activities, fn activity ->
        push(socket, "new_activity", %{
          id: activity.id,
          text: activity.text,
          sender: activity.sender,
          inserted_at: activity.inserted_at
        })
      end)
    end

    {:noreply, socket}
  end

  defp authorized?(conversation_id, %{"conversation_id" => claim_cid}) do
    conversation_id == claim_cid
  end

  defp authorized?(_, _), do: false
end
