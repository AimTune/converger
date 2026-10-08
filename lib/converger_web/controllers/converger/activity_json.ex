defmodule ConvergerWeb.ConvergerAPI.ActivityJSON do
  alias Converger.Activities.Activity
  alias Converger.Activities.Serializer

  @doc """
  An activity set: a page of activities, the watermark to resume after them,
  and `has_more` (true when more activities follow; fetch them by passing
  `watermark` back).
  """
  def activity_set(%{activities: activities, watermark: watermark} = assigns) do
    %{
      activities: Enum.map(activities, &activity_data/1),
      watermark: watermark,
      has_more: Map.get(assigns, :has_more, false)
    }
  end

  def resource_response(%{id: id}) do
    %{id: id}
  end

  @doc """
  Formats an activity into the Converger API response shape.

  Accepts an `Activity` struct or the canonical map from
  `Converger.Activities.Serializer.canonical/1` (the PubSub broadcast payload).
  Both go through the same clause, so REST and WebSocket frames are identical.
  """
  def activity_data(%Activity{} = activity) do
    activity |> Serializer.canonical() |> activity_data()
  end

  def activity_data(%{} = canonical) do
    %{
      id: canonical.id,
      type: canonical.type,
      from: %{id: canonical.sender},
      text: canonical.text,
      timestamp: canonical.inserted_at,
      attachments: canonical.attachments,
      conversationId: canonical.conversation_id,
      channelData: canonical.metadata
    }
  end
end
