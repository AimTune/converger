defmodule ConvergerWeb.ConvergerChannel do
  use ConvergerWeb, :channel

  require Logger

  alias Converger.{Activities, Conversations}
  alias Converger.ConvergerAPI.Watermark
  alias Converger.Pagination
  alias ConvergerWeb.ConvergerAPI.ActivityJSON

  @impl true
  def join("converger:conversation:" <> conversation_id, payload, socket) do
    claims = socket.assigns.converger_claims

    if authorized?(conversation_id, claims) do
      watermark = payload["watermark"]
      socket = assign(socket, :conversation_id, conversation_id)

      # Subscribe to the existing PubSub topic used by the pipeline
      ConvergerWeb.Endpoint.subscribe("conversation:#{conversation_id}")

      send(self(), {:after_join, watermark})
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "invalid_topic"}}

  @impl true
  def handle_info({:after_join, watermark}, socket) do
    conversation_id = socket.assigns.conversation_id
    claims = socket.assigns.converger_claims

    ConvergerWeb.Sockets.track(socket, claims["channel_id"], %{
      tenant_id: claims["tenant_id"],
      conversation_id: conversation_id
    })

    # Without a watermark the client starts live (no replay). Replay is capped
    # at :ws_replay_limit activities (the oldest ones after the watermark);
    # when `has_more` is true the client fetches the rest over
    # GET /api/v1/converger/conversations/:id/activities?watermark=<frame watermark>
    # until `has_more` is false, de-duplicating by activity id against live frames.
    {activities, has_more} =
      case Watermark.decode(watermark) do
        {:ok, nil} ->
          {[], false}

        {:ok, position} ->
          Activities.page_activities_since(conversation_id, position,
            limit: Pagination.config(:ws_replay_limit)
          )

        {:error, _} ->
          {[], false}
      end

    if activities != [] do
      new_watermark = activities |> List.last() |> Map.get(:seq) |> Watermark.encode()

      push(socket, "activitySet", %{
        activities: Enum.map(activities, &ActivityJSON.activity_data/1),
        watermark: new_watermark,
        has_more: has_more
      })
    end

    {:noreply, socket}
  end

  # Handle PubSub broadcasts from the pipeline (conversation:{id} topic)
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "new_activity", payload: payload}, socket) do
    watermark = Watermark.encode(payload.seq)

    activity_set = %{
      activities: [ActivityJSON.activity_data(payload)],
      watermark: watermark,
      has_more: false
    }

    push(socket, "activitySet", activity_set)
    {:noreply, socket}
  end

  # Handle delivery status broadcasts
  def handle_info(%Phoenix.Socket.Broadcast{event: "delivery_status"}, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp authorized?(conversation_id, %{"conversation_id" => claim_cid})
       when is_binary(claim_cid) do
    conversation_id == claim_cid
  end

  defp authorized?(conversation_id, %{"channel_id" => channel_id, "tenant_id" => tenant_id}) do
    case Conversations.get_conversation(conversation_id, tenant_id) do
      %Conversations.Conversation{channel_id: ^channel_id} -> true
      _ -> false
    end
  end

  defp authorized?(_, _), do: false
end
