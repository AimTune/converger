defmodule ConvergerWeb.ConversationChannel do
  use ConvergerWeb, :channel

  require Logger

  alias Converger.{Activities, Conversations, Channels}
  alias Converger.Channels.Adapter

  @impl true
  def join("conversation:" <> conversation_id, payload, socket) do
    claims = socket.assigns[:claims] || %{}

    if authorized?(conversation_id, claims) do
      send(self(), {:after_join, payload})
      {:ok, socket}
    else
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
        handle_activity(socket.assigns[:channel], activity_params)
        {:reply, :ok, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "invalid_activity"}}, socket}
    end
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

    Logger.info("WebSocket channel joined",
      conversation_id: conversation_id,
      tenant_id: conversation.tenant_id
    )

    if last_id = payload["last_activity_id"] do
      conversation_id
      |> Activities.list_activities_after(last_id)
      |> Enum.each(fn activity ->
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

  defp handle_activity(channel, activity_params) do
    Task.start(fn ->
      Adapter.deliver_activity(
        channel,
        struct(Converger.Activities.Activity, %{
          tenant_id: activity_params["tenant_id"],
          conversation_id: activity_params["conversation_id"],
          text: activity_params["text"],
          sender: activity_params["sender"],
          type: activity_params["type"] || "message",
          metadata: activity_params["metadata"] || %{},
          attachments: activity_params["attachments"] || []
        })
      )
    end)
  end

  defp authorized?(conversation_id, %{"conversation_id" => claim_cid}) do
    conversation_id == claim_cid
  end

  defp authorized?(_, _), do: false
end
