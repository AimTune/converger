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
  plain `message` with the text fallback, or nothing when there is none;
  `tool_call` traces only reach channels whose config sets
  `show_tool_traces: true`, as a `name: status` line.

  Internal types (`deliveryReceipt`) are never delivered to channels.
  WebSocket clients always receive every type through the PubSub broadcast.
  """

  alias Converger.Activities.Activity
  alias Converger.Channels.Adapter

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

      typed_message?(activity) and not native_message_type?(activity, channel_type) ->
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

  defp native_message_type?(%{message_type: message_type}, channel_type) do
    case Adapter.message_types(channel_type) do
      :all -> true
      types -> message_type in types
    end
  end

  # A typed message (#68) the channel cannot render: tool traces only when
  # the channel enables `show_tool_traces`, everything else as its text
  # fallback (`activities.text`), or skipped when there is none
  # (docs/protocol/messages.md, section 5).
  defp plan_message_type(%{message_type: "tool_call"} = activity, channel) do
    data = (Map.get(activity, :payload) || %{})["data"] || %{}

    if show_tool_traces?(channel) and is_binary(data["name"]),
      do: {:downgrade, plain(activity, "#{data["name"]}: #{data["status"]}")},
      else: :skip
  end

  defp plan_message_type(activity, _channel) do
    case text(activity) do
      nil -> :skip
      text -> {:downgrade, plain(activity, text)}
    end
  end

  defp plain(activity, text),
    do: %{activity | type: "message", text: text, message_type: nil, payload: nil}

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
