defmodule ConvergerWeb.Protocol.Access do
  @moduledoc """
  Which conversations a Converger token may follow, shared by the Phoenix
  binding (`ConvergerWeb.ConvergerChannel`) and the native channel-scoped
  connection (`ConvergerWeb.Protocol.ChannelSession`).

  Only conversation tokens and channel-scoped tokens (`scope: "channel"`) may
  follow a conversation. An unscoped channel-level token (from
  `POST /tokens/generate`, typically held by an end-user widget) must first
  create or resume a conversation, which returns a conversation token;
  letting it follow any conversation of the channel would expose other users'
  conversations.

  A conversation is

    * **owned** when it belongs to the token's channel (or the token was
      issued for exactly that conversation);
    * **routed** when the token's channel is a `websocket` channel that an
      enabled routing rule targets from the conversation's channel (a bot or
      agent channel, docs/protocol/v1.md section 10).
  """

  alias Converger.{Conversations, RoutingRules}

  @doc """
  `{:ok, :owned | :routed, conversation}` when `claims` (of `channel`) may
  follow `conversation_id`, else `:error`.
  """
  def conversation(conversation_id, channel, claims) do
    restricted = claims["conversation_id"]

    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         true <- is_binary(restricted) or claims["scope"] == "channel",
         true <- is_nil(restricted) or restricted == conversation_id,
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, channel.tenant_id) do
      cond do
        conversation.channel_id == channel.id ->
          {:ok, :owned, conversation}

        channel.type == "websocket" and
            RoutingRules.routes_to?(conversation.channel_id, channel.id, channel.tenant_id) ->
          {:ok, :routed, conversation}

        # A token issued for this one conversation.
        is_binary(restricted) ->
          {:ok, :owned, conversation}

        true ->
          :error
      end
    else
      _ -> :error
    end
  end
end
