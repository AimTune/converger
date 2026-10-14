defmodule Converger.Inbound.Answers do
  @moduledoc """
  Normalises a user's answer to an actionable message (docs/protocol/messages.md
  section 6, ADR-0064) before the inbound message becomes an activity.

  Whatever the channel, the answer becomes an ordinary `message` with

    * `text` - the action's `value` when it is a string, else its `label`;
    * `metadata.action` - `%{"label", "value", "source"}`, `source` one of
      `button`, `list`, `keyboard`, `numeric`, `email`, `web`;
    * `reply_to_id` - the activity that offered the action.

  Two ways in:

    * an adapter that rendered the actions natively puts the tapped
      action's answer key (`Converger.Channels.RichContent.ref/2`, sent as the
      button id or callback data) in the message as `"answer" => %{"ref",
      "source", "label"}`. The key must name an action of an activity of the
      same conversation; otherwise the message keeps its text (`"label"`,
      the provider's button title, when given).
    * a numeric reply (`"2"`) on a channel that does not forward the canonical
      activity (`Converger.Channels.Adapter.message_types/1` is not `:all`)
      picks that numbered action of the most recent actionable message of the
      conversation sent by someone else, at most 24 hours old. Otherwise it is
      plain text.

  A message that already has `metadata.action` (a WebSocket client's answer)
  or a typed payload is left as it is.
  """

  alias Converger.Activities
  alias Converger.Channels.{Adapter, RichContent}

  @window_seconds 24 * 60 * 60

  @doc "How old (seconds) an actionable message a numeric reply can answer may be."
  def window_seconds, do: @window_seconds

  @doc "The message with its answer normalised (see the module doc)."
  def normalise(channel, conversation, message) do
    {answer, message} = Map.pop(message, "answer")

    cond do
      Map.get(message, "type", "message") != "message" -> message
      is_binary(message["message_type"]) -> message
      is_map(message["metadata"]) and Map.has_key?(message["metadata"], "action") -> message
      is_map(answer) -> from_ref(conversation, message, answer)
      true -> from_number(channel, conversation, message)
    end
  end

  defp from_ref(conversation, message, answer) do
    with {:ok, activity_id, index} <- RichContent.parse_ref(answer["ref"]),
         %Activities.Activity{} = activity <-
           Activities.get_conversation_activity(conversation.id, activity_id),
         %{} = action <- find_action(activity, &(&1["index"] == index)) do
      apply_answer(message, activity, action, answer["source"] || "button")
    else
      _ ->
        case answer["label"] do
          label when is_binary(label) and label != "" -> Map.put(message, "text", label)
          _ -> message
        end
    end
  end

  defp from_number(channel, conversation, message) do
    with false <- Adapter.message_types(channel.type) == :all,
         [] <- List.wrap(message["attachments"]),
         {:ok, number} <- RichContent.numeric(message["text"]),
         %Activities.Activity{} = activity <- latest_actionable(conversation, message),
         %{} = action <- find_action(activity, &(&1["number"] == number)) do
      source = if channel.type == "email", do: "email", else: "numeric"
      apply_answer(message, activity, action, source)
    else
      _ -> message
    end
  end

  defp latest_actionable(conversation, message) do
    since = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

    conversation.id
    |> Activities.recent_typed_messages(
      RichContent.actionable_types(),
      since,
      message["sender"]
    )
    |> Enum.find(&(RichContent.choices(RichContent.activity_actions(&1)) != []))
  end

  defp find_action(activity, fun) do
    activity
    |> RichContent.activity_actions()
    |> RichContent.choices()
    |> Enum.find(fun)
  end

  defp apply_answer(message, activity, action, source) do
    {text, action} = RichContent.answer(action, source)
    metadata = if is_map(message["metadata"]), do: message["metadata"], else: %{}

    message
    |> Map.put("text", text)
    |> Map.put("metadata", Map.put(metadata, "action", action))
    |> Map.put("reply_to_id", activity.id)
  end
end
