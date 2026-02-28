defmodule ConvergerWeb.Helpers.Authorization do
  @moduledoc """
  Shared authorization helpers for controllers that work with
  conversation-scoped claims (e.g. Converger API controllers).
  """

  @doc """
  Checks whether the given claims permit access to a conversation.

  Returns `:ok` when:
    - the claims contain a `conversation_id` that matches the requested one
    - the claims have `conversation_id` set to `nil` (unscoped token)
    - the claims have no `conversation_id` key at all

  Returns `{:error, :forbidden}` otherwise.
  """
  def authorize_conversation(%{"conversation_id" => conv_id}, conv_id)
      when is_binary(conv_id),
      do: :ok

  def authorize_conversation(%{"conversation_id" => nil}, _), do: :ok
  def authorize_conversation(claims, _) when not is_map_key(claims, "conversation_id"), do: :ok
  def authorize_conversation(_, _), do: {:error, :forbidden}
end
