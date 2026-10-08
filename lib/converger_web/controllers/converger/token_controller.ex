defmodule ConvergerWeb.ConvergerAPI.TokenController do
  use ConvergerWeb, :controller

  alias Converger.Auth.ConvergerToken

  # Limited per channel (the secret's channel for generate, the token's channel
  # for refresh) rather than per IP, so tenants behind a shared NAT do not
  # share a bucket.
  plug ConvergerWeb.Plugs.RateLimit, bucket: :token_generate, scope: :channel

  action_fallback ConvergerWeb.FallbackController

  def generate(conn, params) do
    case conn.assigns do
      %{auth_mode: :secret, channel: channel} ->
        {:ok, token, _claims} =
          ConvergerToken.generate_token(channel, user_id: get_in(params, ["user", "id"]))

        conn
        |> put_status(:ok)
        |> json(%{
          conversationId: nil,
          token: token,
          expires_in: ConvergerToken.default_expiry()
        })

      %{auth_mode: :token} ->
        {:error, "Token generation requires channel secret, not a token"}

      _ ->
        {:error, :unauthorized}
    end
  end

  def refresh(conn, _params) do
    case conn.assigns do
      %{auth_mode: :token, converger_claims: claims} ->
        channel = Converger.Channels.get_channel!(claims["channel_id"])

        {:ok, token, _claims} =
          ConvergerToken.generate_token(channel,
            conversation_id: claims["conversation_id"],
            user_id: claims["user_id"]
          )

        conn
        |> put_status(:ok)
        |> json(%{
          conversationId: claims["conversation_id"],
          token: token,
          expires_in: ConvergerToken.default_expiry()
        })

      _ ->
        {:error, :unauthorized}
    end
  end
end
