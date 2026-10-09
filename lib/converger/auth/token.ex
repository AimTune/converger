defmodule Converger.Auth.Token do
  @moduledoc """
  Joken configuration for the conversation-scoped tokens used to join the
  WebSocket conversation channel.
  """

  use Joken.Config

  alias Converger.Auth.Signer

  @impl true
  def token_config do
    # 1 hour default
    default_claims(default_exp: 3600)
    |> add_claim("conversation_id", nil, &(&1 != nil))
    |> add_claim("tenant_id", nil, &(&1 != nil))
    |> add_claim("sub", nil, &(&1 != nil))
  end

  def generate_token(conversation, tenant, user_id) do
    claims = %{
      "conversation_id" => conversation.id,
      "tenant_id" => tenant.id,
      "sub" => user_id
    }

    generate_and_sign(claims, Signer.signer())
  end

  def generate_channel_token(channel) do
    claims = %{
      "typ" => "channel",
      "channel_id" => channel.id,
      "tenant_id" => channel.tenant_id,
      "sub" => "channel_#{channel.id}"
    }

    generate_and_sign(claims, Signer.signer())
  end

  @doc """
  Returns `{:ok, channel_id, tenant_id}` when verified `claims` are a channel
  token, `:error` otherwise.

  All token types share one signer, so a valid signature alone does not say
  what a token is. Channel tokens carry `typ: "channel"`; channel tokens
  issued before that claim existed are recognised by their exact shape
  (`sub == "channel_<channel_id>"`, no conversation, not a Converger client
  token).
  """
  def channel_token_claims(
        %{"typ" => "channel", "channel_id" => channel_id, "tenant_id" => tenant_id} = claims
      )
      when is_binary(channel_id) and is_binary(tenant_id) do
    if Map.has_key?(claims, "conversation_id"), do: :error, else: {:ok, channel_id, tenant_id}
  end

  def channel_token_claims(
        %{"channel_id" => channel_id, "tenant_id" => tenant_id, "sub" => sub} = claims
      )
      when is_binary(channel_id) and is_binary(tenant_id) do
    legacy? =
      sub == "channel_" <> channel_id and not Map.has_key?(claims, "conversation_id") and
        not Map.has_key?(claims, "type") and not Map.has_key?(claims, "typ")

    if legacy?, do: {:ok, channel_id, tenant_id}, else: :error
  end

  def channel_token_claims(_claims), do: :error

  def verify_token(token) do
    verify_and_validate(token, Signer.signer())
  end
end
