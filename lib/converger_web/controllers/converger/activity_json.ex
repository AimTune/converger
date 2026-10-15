defmodule ConvergerWeb.ConvergerAPI.ActivityJSON do
  alias Converger.Activities.Activity
  alias Converger.Activities.Serializer
  alias ConvergerWeb.Protocol.Frames

  @doc """
  An activity set: a page of activities, the watermark to resume after them,
  and `has_more` (true when more activities follow; fetch them by passing
  `watermark` back).

  A backward page (`backward: true`, ADR-0065) adds `cursor`: the seq to pass
  as `before` for the next older page, or nil when there is none (`has_more`
  then means older activities exist). With `format: :frames` the page is
  `frames`, the Protocol v1 frames the WebSocket delivers to `user_id`
  (`ConvergerWeb.Protocol.Frames.activity/3`), instead of `activities`.
  """
  def activity_set(%{activities: activities, watermark: watermark} = assigns) do
    set = %{watermark: watermark, has_more: Map.get(assigns, :has_more, false)}

    set =
      case Map.get(assigns, :format, :activities) do
        :frames ->
          user_id = Map.get(assigns, :user_id)
          Map.put(set, :frames, Enum.map(activities, &Frames.activity(&1, user_id, false)))

        :activities ->
          Map.put(set, :activities, Enum.map(activities, &activity_data/1))
      end

    if Map.get(assigns, :backward, false),
      do: Map.put(set, :cursor, Map.get(assigns, :cursor)),
      else: set
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
      seq: Map.get(canonical, :seq),
      type: canonical.type,
      from: %{id: canonical.sender},
      text: canonical.text,
      timestamp: canonical.inserted_at,
      attachments: canonical.attachments,
      conversationId: canonical.conversation_id,
      channelData: canonical.metadata,
      replyToId: Map.get(canonical, :reply_to_id),
      messageType: Map.get(canonical, :message_type),
      payload: Map.get(canonical, :payload),
      editedAt: Map.get(canonical, :edited_at),
      deletedAt: Map.get(canonical, :deleted_at)
    }
  end
end
