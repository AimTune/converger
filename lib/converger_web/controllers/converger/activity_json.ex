defmodule ConvergerWeb.ConvergerAPI.ActivityJSON do
  alias Converger.Activities.Activity

  def activity_set(%{activities: activities, watermark: watermark}) do
    %{
      activities: Enum.map(activities, &activity_data/1),
      watermark: watermark
    }
  end

  def resource_response(%{id: id}) do
    %{id: id}
  end

  @doc """
  Formats an Activity struct into the Converger API response shape.
  Also accepts plain maps (e.g. PubSub broadcast payloads).
  """
  def activity_data(%Activity{} = activity) do
    %{
      id: activity.id,
      type: activity.type,
      from: %{id: activity.sender},
      text: activity.text,
      timestamp: activity.inserted_at,
      attachments: activity.attachments || [],
      conversationId: activity.conversation_id,
      channelData: activity.metadata
    }
  end

  def activity_data(%{} = payload) do
    %{
      id: payload.id,
      type: Map.get(payload, :type, "message"),
      from: %{id: payload.sender},
      text: payload.text,
      timestamp: payload.inserted_at,
      attachments: Map.get(payload, :attachments, []),
      conversationId: Map.get(payload, :conversation_id)
    }
  end
end
