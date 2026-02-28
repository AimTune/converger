defmodule Converger.Auth.ConvergerToken do
  use Joken.Config

  @default_expiry 1800

  @impl true
  def token_config do
    default_claims(default_exp: @default_expiry)
    |> add_claim("type", fn -> "converger" end, &(&1 == "converger"))
    |> add_claim("channel_id", nil, &is_binary/1)
    |> add_claim("tenant_id", nil, &is_binary/1)
    |> add_claim("sub", nil, &is_binary/1)
  end

  def generate_token(channel, opts \\ []) do
    conversation_id = Keyword.get(opts, :conversation_id)
    expiry = Keyword.get(opts, :expires_in, @default_expiry)

    claims = %{
      "type" => "converger",
      "channel_id" => channel.id,
      "tenant_id" => channel.tenant_id,
      "sub" => "converger_#{channel.id}",
      "exp" => Joken.current_time() + expiry
    }

    claims =
      if conversation_id,
        do: Map.put(claims, "conversation_id", conversation_id),
        else: claims

    generate_and_sign(claims, Converger.Auth.Signer.signer())
  end

  def generate_conversation_token(channel, conversation_id, opts \\ []) do
    generate_token(channel, Keyword.put(opts, :conversation_id, conversation_id))
  end

  def verify_token(token) do
    case verify_and_validate(token, Converger.Auth.Signer.signer()) do
      {:ok, %{"type" => "converger"} = claims} -> {:ok, claims}
      {:ok, _} -> {:error, :invalid_token_type}
      error -> error
    end
  end

  def refresh_token(token) do
    case verify_token(token) do
      {:ok, claims} ->
        channel = Converger.Channels.get_channel!(claims["channel_id"])

        generate_token(channel,
          conversation_id: claims["conversation_id"],
          expires_in: @default_expiry
        )

      error ->
        error
    end
  end

  def default_expiry, do: @default_expiry

end
