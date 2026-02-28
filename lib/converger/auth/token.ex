defmodule Converger.Auth.Token do
  use Joken.Config

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

    generate_and_sign(claims, Converger.Auth.Signer.signer())
  end

  def generate_channel_token(channel) do
    claims = %{
      "channel_id" => channel.id,
      "tenant_id" => channel.tenant_id,
      "sub" => "channel_#{channel.id}"
    }

    generate_and_sign(claims, Converger.Auth.Signer.signer())
  end

  def verify_token(token) do
    verify_and_validate(token, Converger.Auth.Signer.signer())
  end

end
