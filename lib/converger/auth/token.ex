defmodule Converger.Auth.Token do
  @moduledoc """
  Legacy (pre-Protocol v1) tokens. **Deprecated** (#23): use
  `Converger.Auth.ConvergerToken` and the Converger API instead.

  Two shapes share this module:

    * channel token (`generate_channel_token/1`): `typ: "channel"`,
      `channel_id`, no `conversation_id` (see `channel_token_claims/1`). Sent as `x-channel-token` to the tenant API.
    * conversation token (`generate_token/3`): `conversation_id`, no
      `channel_id`. Held by end users to join the legacy
      `conversation:<id>` WebSocket topic.

  All tokens share one signer (`Converger.Auth.Signer`), so a verifier must
  check the shape, not only the signature: `verify_channel_token/1` and
  `verify_conversation_token/1` do, and Converger API tokens
  (`type: "converger"`) are never accepted here.
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

  @doc "Verify a legacy token of either shape."
  def verify_token(token) do
    case verify_and_validate(token, Signer.signer()) do
      {:ok, %{"type" => _}} -> {:error, :invalid_token_type}
      other -> other
    end
  end

  @doc """
  Verify a channel token. Conversation tokens (held by end users) and
  Converger API tokens are rejected: a channel token authenticates as the
  whole tenant on the tenant API.
  """
  def verify_channel_token(token) do
    with {:ok, claims} <- verify_token(token),
         {:ok, _channel_id, _tenant_id} <- channel_token_claims(claims) do
      {:ok, claims}
    else
      :error -> {:error, :invalid_token_type}
      error -> error
    end
  end

  @doc "Verify a conversation token (the legacy WebSocket credential)."
  def verify_conversation_token(token) do
    case verify_token(token) do
      {:ok, %{"conversation_id" => conversation_id, "tenant_id" => tenant_id} = claims}
      when is_binary(conversation_id) and is_binary(tenant_id) ->
        {:ok, claims}

      {:ok, _claims} ->
        {:error, :invalid_token_type}

      error ->
        error
    end
  end
end
