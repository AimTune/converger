defmodule ConvergerWeb.Helpers.Authorization do
  @moduledoc """
  Shared authorization helpers for controllers that work with
  conversation-scoped claims (Converger API controllers).

  A Converger token is always bound to one channel (`channel_id`) and
  optionally to one conversation (`conversation_id`). Access to a
  conversation requires both checks:

    * `authorize_conversation/2` - the token's `conversation_id`, when set,
      must be the requested conversation;
    * `authorize_channel/2` - the conversation must belong to the token's
      channel. Without it an unscoped token (as returned by
      `POST /tokens/generate`) could read and write every conversation of
      the tenant, on any channel.
  """

  alias Converger.Conversations.Conversation

  @doc """
  Checks the token's conversation binding.

  Returns `:ok` when the claims carry the requested `conversation_id`, or
  carry none (an unscoped, channel-level token); `{:error, :forbidden}`
  otherwise.
  """
  def authorize_conversation(%{"conversation_id" => conv_id}, conv_id)
      when is_binary(conv_id),
      do: :ok

  def authorize_conversation(%{"conversation_id" => nil}, _), do: :ok
  def authorize_conversation(claims, _) when not is_map_key(claims, "conversation_id"), do: :ok
  def authorize_conversation(_, _), do: {:error, :forbidden}

  @doc """
  Checks that `conversation` belongs to the token's tenant and channel.

  Returns `{:error, :not_found}` (not `:forbidden`) on mismatch, so a token
  cannot probe for conversations of other channels.
  """
  def authorize_channel(
        %{"tenant_id" => tenant_id, "channel_id" => channel_id},
        %Conversation{tenant_id: tenant_id, channel_id: channel_id}
      )
      when is_binary(tenant_id) and is_binary(channel_id),
      do: :ok

  def authorize_channel(_claims, _conversation), do: {:error, :not_found}
end
