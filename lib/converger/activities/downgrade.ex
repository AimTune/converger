defmodule Converger.Activities.Downgrade do
  @moduledoc """
  Decides how an activity reaches a channel whose adapter cannot deliver its
  type natively.

  Adapters declare the activity types they deliver with an
  `activity_types:` entry in `capabilities/0`
  (`Converger.Channels.Adapter.activity_types/1`). For any other type the
  channel config key `"unsupported_activities"` decides:

    * `"downgrade"` (default) - the activity is delivered as a plain
      `message` whose text describes it, for example
      `messageReaction` -> `"user reacted with 👍"`. Types without a
      meaningful text (typing, a removed reaction, an event without text)
      are skipped.
    * `"skip"` - the channel does not receive it.

  Typed messages (`message_type`, #68) are delivered natively when the
  adapter declares the type in a `message_types:` capability entry (`:all`
  for adapters that forward the canonical activity, see
  `Converger.Channels.Adapter.message_types/1`). Otherwise the channel gets a
  plain `message` with the text rendering of `Converger.Channels.RichContent`
  (the prompt and its actions as a numbered list), or nothing when there is
  none; `tool_call` traces only reach channels whose config sets
  `show_tool_traces: true`, as a `name: status` line; GenUI streams arrive as
  one text message when done. See ADR-0064.

  Internal types (`deliveryReceipt`) are never delivered to channels.
  WebSocket clients always receive every type through the PubSub broadcast.
  """

  alias Converger.Activities.Activity
  alias Converger.Channels.{Adapter, RichContent}

  @policies ~w(downgrade skip)
  @default_policy "downgrade"

  @doc "Accepted values of the channel config key `unsupported_activities`."
  def policies, do: @policies

  @doc """
  `:native`, `{:downgrade, activity}` (a `message` copy to deliver instead) or
  `:skip`.
  """
  def plan(%{type: type} = activity, %{type: channel_type} = channel) do
    cond do
      type in Activity.internal_types() ->
        :skip

      typed_message?(activity) and end_user_channel?(channel_type) ->
        plan_message_type(activity, channel)

      type in Adapter.activity_types(channel_type) ->
        :native

      policy(channel) == "skip" ->
        :skip

      true ->
        case text(activity) do
          nil -> :skip
          text -> {:downgrade, %{activity | type: "message", text: text}}
        end
    end
  end

  defp typed_message?(activity), do: is_binary(Map.get(activity, :message_type))

  defp end_user_channel?(channel_type), do: Adapter.message_types(channel_type) != :all

  # A typed message (#68) on an end-user channel (one that lists its
  # activity types), docs/protocol/messages.md section 5:
  #
  #   * `tool_call` - only with `show_tool_traces`, as a `name: status` line;
  #   * `genui` - the text chunks of the stream joined into one message when
  #     the stream is `done`; nothing before, `ui` and `event` chunks never;
  #   * an `interrupt` with a `tool` or an `event` - skipped;
  #   * a type the adapter declares in `message_types` - delivered natively;
  #     media, location and contact as the legacy attachment the adapter
  #     already renders (`RichContent.attachment/2`);
  #   * anything else - a plain `message` with the text rendering of
  #     `RichContent.text/1` (numbered actions), else the stored fallback.
  defp plan_message_type(%{message_type: "tool_call"} = activity, channel) do
    data = (Map.get(activity, :payload) || %{})["data"] || %{}

    if show_tool_traces?(channel) and is_binary(data["name"]),
      do: {:downgrade, plain(activity, "#{data["name"]}: #{data["status"]}")},
      else: :skip
  end

  defp plan_message_type(%{message_type: "genui"} = activity, _channel) do
    case genui_text(activity) do
      nil -> :skip
      text -> {:downgrade, plain(activity, text)}
    end
  end

  defp plan_message_type(%{message_type: message_type} = activity, channel) do
    cond do
      RichContent.skip?(activity) ->
        :skip

      message_type in Adapter.message_types(channel.type) ->
        native_message(activity)

      true ->
        text_message(activity)
    end
  end

  defp native_message(%{message_type: type, payload: payload} = activity) do
    if type in RichContent.media_types() or type in RichContent.well_known_types() do
      case RichContent.attachment(type, payload) do
        {caption, attachment} ->
          {:downgrade, %{plain(activity, caption) | attachments: [attachment]}}

        nil ->
          text_message(activity)
      end
    else
      :native
    end
  end

  defp text_message(activity) do
    case RichContent.text(activity) || text(activity) do
      nil -> :skip
      text -> {:downgrade, plain(activity, text)}
    end
  end

  defp plain(activity, text),
    do: %{activity | type: "message", text: text, message_type: nil, payload: nil}

  # The text of a GenUI stream, on its `done` chunk: its text runs in order,
  # each the concatenation of the deltas that share its chunk id (mekik
  # PROTOCOL.md 4.1, as chativa renders them; ADR-0072).
  defp genui_text(%{payload: %{"done" => true, "streamId" => stream_id} = payload} = activity)
       when is_binary(stream_id) do
    earlier =
      case Map.get(activity, :conversation_id) do
        id when is_binary(id) -> Converger.Activities.genui_stream_payloads(id, stream_id)
        _ -> []
      end

    # The stored stream already holds this `done` payload once the activity
    # is committed; a run is concatenated, so it must not count twice.
    payloads = if payload in earlier, do: earlier, else: earlier ++ [payload]
    {order, contents} = Enum.reduce(payloads, {[], %{}}, &collect_text_chunk/2)

    order
    |> Enum.reverse()
    |> Enum.map(&String.trim(contents[&1]))
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      texts -> Enum.join(texts, "\n\n")
    end
  end

  defp genui_text(_activity), do: nil

  defp collect_text_chunk(
         %{"chunk" => %{"type" => "text", "content" => content} = chunk},
         {order, contents}
       )
       when is_binary(content) do
    key = Map.get(chunk, "id", make_ref())
    order = if Map.has_key?(contents, key), do: order, else: [key | order]
    {order, Map.update(contents, key, content, &(&1 <> content))}
  end

  defp collect_text_chunk(_payload, acc), do: acc

  defp show_tool_traces?(channel),
    do: (Map.get(channel, :config) || %{})["show_tool_traces"] == true

  @doc "The channel's policy for unsupported types: `downgrade` or `skip`."
  def policy(channel) do
    case (Map.get(channel, :config) || %{})["unsupported_activities"] do
      policy when policy in @policies -> policy
      _ -> @default_policy
    end
  end

  @doc "Plain-text rendering of an activity, or nil when it has none worth sending."
  def text(%{type: "messageReaction", sender: sender, text: emoji}) do
    if blank?(emoji), do: nil, else: "#{sender} reacted with #{emoji}"
  end

  def text(%{type: "messageUpdate", text: text}) do
    if blank?(text), do: nil, else: "(edited) #{text}"
  end

  def text(%{type: "messageDelete", sender: sender}), do: "#{sender} deleted a message"

  def text(%{type: "typing"}), do: nil

  def text(%{text: text}), do: if(blank?(text), do: nil, else: text)

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""
end
