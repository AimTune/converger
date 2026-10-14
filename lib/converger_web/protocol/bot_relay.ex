defmodule ConvergerWeb.Protocol.BotRelay do
  @moduledoc """
  The bot channel of a conversation (docs/protocol/v1.md, section 9).

  A conversation's **bot channels** are the channels that enabled routing
  rules target from its origin channel and that speak mekik/1 to a bot: a
  `websocket` channel with at least one channel-scoped connection (an agent
  socket, `ConvergerWeb.Protocol.ChannelSession`, the `@converger/agent` SDK
  or the `@mekik/converger` transport), or a channel whose adapter has the
  `:bot_relay` capability (the `mekik` adapter, Mode A of #64).

  The relay has three directions:

    * **end user to bot** (`forward/2`): the frames only a bot can answer
      (`resume`, `genui_event`, `client_tools`, `client_skills`, `abort`,
      `survey`, `regenerate`, `edit`) are broadcast unchanged to the bot
      channels, on the channel topic as `bot_frame`. Without a bot channel
      the sender gets `bot_unavailable`. A user turn's `meta` (mekik/1
      per-turn context, never stored) follows the same way as `turn_meta`.
    * **bot to end users** (`relay/2`): the bot's transient frames (`run`,
      `genui_components`, `skills`, `error`) are broadcast to the
      conversation's connections as `bot_transient`. Its persistent frames are
      stored like any message (`Converger.Activities.MessagePayload`) and fan
      out from there.
    * **turns delivered to a bot** (`turn_frame/3`): a user turn that answers
      an open `interrupt` (its `reply_to_id` names the interrupt, for example a
      tapped WhatsApp button) reaches the bot as `resume {answers: {id:
      value}}` instead of a message (messages.md section 6).

  The turn lock is the bot's: Converger does not serialise turns.
  """

  alias Converger.Activities
  alias Converger.Activities.Activity
  alias Converger.Channels
  alias Converger.Channels.{Adapter, Channel}
  alias Converger.Conversations.Conversation
  alias Converger.RoutingRules

  # Client frames that only the bot can answer (section 9).
  @forwarded ~w(resume genui_event client_tools client_skills abort survey regenerate edit)

  # Transient bot frames relayed to the conversation's connections. A bot's
  # typing goes through ConversationSignals like everyone else's.
  @transient ~w(run genui_components skills error)

  @doc "Client frame types forwarded to the bot channel."
  def forwarded_types, do: @forwarded

  @doc "Transient bot frame types relayed to the conversation's connections."
  def transient_types, do: @transient

  @doc "The PubSub topic of a channel's bot frames (the `websocket` adapter's channel topic)."
  def channel_topic(channel_id), do: "channel:#{channel_id}"

  @doc "The conversation's bot channels (see the module doc)."
  @spec bot_channels(Conversation.t()) :: [Channel.t()]
  def bot_channels(%Conversation{} = conversation) do
    conversation
    |> Conversation.origin_channel_id()
    |> RoutingRules.resolve_target_channels(conversation.tenant_id)
    |> Enum.flat_map(fn channel_id ->
      case Channels.get_active_channel(channel_id, conversation.tenant_id) do
        {:ok, channel} -> if bot_channel?(channel), do: [channel], else: []
        _ -> []
      end
    end)
  end

  @doc "Whether `channel` speaks to a bot now (see the module doc)."
  def bot_channel?(%{type: type, id: id}) do
    Adapter.capability?(type, :bot_relay) or
      (type == "websocket" and ConvergerWeb.Sockets.count_agents(id) > 0)
  end

  @doc """
  Forward an end user's bot-only frame to the conversation's bot channels.
  Returns `:ok` or `{:error, :bot_unavailable}`.
  """
  @spec forward(Conversation.t(), map()) :: :ok | {:error, :bot_unavailable}
  def forward(%Conversation{} = conversation, frame) do
    case bot_channels(conversation) do
      [] ->
        {:error, :bot_unavailable}

      channels ->
        Enum.each(channels, &broadcast_bot(&1.id, conversation.id, frame))
        :ok
    end
  end

  @doc """
  Pass a user turn's `meta` (mekik/1 per-turn context) to the bot channels,
  ahead of the turn, keyed by the turn's idempotency key. Never stored.
  """
  def turn_meta(%Conversation{} = conversation, key, meta)
      when is_binary(key) and is_map(meta) and map_size(meta) > 0 do
    for channel <- bot_channels(conversation) do
      ConvergerWeb.Endpoint.broadcast(channel_topic(channel.id), "turn_meta", %{
        conversation_id: conversation.id,
        key: key,
        meta: meta
      })
    end

    :ok
  end

  def turn_meta(_conversation, _key, _meta), do: :ok

  defp broadcast_bot(channel_id, conversation_id, frame) do
    ConvergerWeb.Endpoint.broadcast(channel_topic(channel_id), "bot_frame", %{
      conversation_id: conversation_id,
      frame: frame
    })
  end

  @doc "Relay a bot's transient frame to every connection of the conversation."
  def relay(conversation_id, %{"type" => type} = frame) when type in @transient do
    ConvergerWeb.Endpoint.broadcast("conversation:#{conversation_id}", "bot_transient", frame)
  end

  @doc """
  The idempotency key of a bot's send: its clientId (or mekik message `id`) is
  only unique within one conversation (mekik numbers `msg-1`, `msg-2`, ... per
  conversation), so the key names the conversation.
  """
  def client_key(sender, conversation_id, client_id),
    do: "bot:#{sender}:#{conversation_id}:#{client_id}"

  @doc """
  The frame a bot receives for a delivered activity: `resume` when it is a
  user turn answering an open interrupt, else the activity's frame as seen by
  `viewer` (`ConvergerWeb.Protocol.Frames.activity/3`). `frame` is the
  already rendered frame.
  """
  def turn_frame(
        %{"from" => "user", "replyTo" => %{"id" => reply_to_id}} = frame,
        conversation_id
      ) do
    case interrupt_answer(conversation_id, reply_to_id, frame) do
      nil -> frame
      {interrupt_id, value} -> %{"type" => "resume", "answers" => %{interrupt_id => value}}
    end
  end

  def turn_frame(frame, _conversation_id), do: frame

  # The interrupt a turn answers, when it is still open, and the answer: the
  # tapped action's value (`metadata.action.value`, any JSON), else the text.
  defp interrupt_answer(conversation_id, reply_to_id, frame) do
    with {:ok, _} <- Ecto.UUID.cast(reply_to_id),
         %Activity{message_type: "interrupt", payload: %{"id" => interrupt_id}} = interrupt <-
           Activities.get_activity(reply_to_id),
         true <- interrupt.conversation_id == conversation_id,
         true <- Activities.interrupt_open?(interrupt) do
      {interrupt_id, answer_value(frame)}
    else
      _ -> nil
    end
  end

  defp answer_value(%{"metadata" => %{"action" => %{"value" => value}}}), do: value
  defp answer_value(%{"metadata" => %{"action" => %{"label" => label}}}), do: label
  defp answer_value(%{"data" => %{"text" => text}}), do: text
  defp answer_value(_frame), do: nil
end
