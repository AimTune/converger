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
