defmodule ConvergerWeb.ConvergerAPI.TokenController do
  use ConvergerWeb, :controller

  alias Converger.Auth.ConvergerToken

  plug ConvergerWeb.Plugs.RateLimit,
       [scope: :ip, key_prefix: "cg_token", limit: 10, scale_ms: 60_000]

  action_fallback ConvergerWeb.FallbackController

  def generate(conn, _params) do
    case conn.assigns do
      %{auth_mode: :secret, channel: channel} ->
        {:ok, token, _claims} = ConvergerToken.generate_token(channel)

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
            conversation_id: claims["conversation_id"]
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
