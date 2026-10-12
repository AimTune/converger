defmodule ConvergerWeb.ConvergerAPI.TokenController do
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Auth.ConvergerToken

  # Limited per channel (the secret's channel for generate, the token's channel
  # for refresh) rather than per IP, so tenants behind a shared NAT do not
  # share a bucket.
  plug ConvergerWeb.Plugs.RateLimit, bucket: :token_generate, scope: :channel

  action_fallback ConvergerWeb.FallbackController

  tags(["Client: Tokens"])

  operation(:generate,
    summary: "Generate a Converger token",
    description:
      "Exchanges the channel secret (server side) for a short-lived, unscoped Converger token for an end user.",
    operation_id: "generateToken",
    security: [%{"channelSecret" => []}],
    request_body: json_schema("Options", ref("ClientTokenRequest")),
    responses:
      with_errors(%{200 => json_schema("The token", ref("ClientToken"))}, [400, 401, 403, 429])
  )

  operation(:refresh,
    summary: "Refresh a Converger token",
    description: "A new token with the same claims and a new expiry.",
    operation_id: "refreshToken",
    security: [%{"convergerToken" => []}],
    responses:
      with_errors(%{200 => json_schema("The token", ref("ClientToken"))}, [401, 403, 429])
  )

  def generate(conn, params) do
    case conn.assigns do
      %{auth_mode: :secret, channel: channel} ->
        scope = params["scope"]

        if is_nil(scope) or scope in ConvergerToken.scopes() do
          {:ok, token, _claims} =
            ConvergerToken.generate_token(channel,
              user_id: get_in(params, ["user", "id"]),
              scope: scope
            )

          conn
          |> put_status(:ok)
          |> json(%{
            conversationId: nil,
            token: token,
            expires_in: ConvergerToken.default_expiry()
          })
        else
          {:error, "scope must be one of: #{Enum.join(ConvergerToken.scopes(), ", ")}"}
        end

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
            user_id: claims["user_id"],
            scope: claims["scope"]
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
