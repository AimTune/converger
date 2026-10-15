defmodule ConvergerWeb.ConvergerAPI.TokenController do
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Auth.{ConvergerToken, Revocations}
  alias ConvergerWeb.{APIError, Sockets}
  alias ConvergerWeb.Plugs.RateLimit

  # Limited per channel (the secret's channel for generate, the token's channel
  # for refresh) rather than per IP, so tenants behind a shared NAT do not
  # share a bucket. Tokens minted through a publishable key refresh against
  # the larger `publishable_token` bucket (ADR-0074): a public widget has many
  # visitors, each refreshing every half hour.
  plug ConvergerWeb.Plugs.RateLimit,
       [bucket: :token_generate, scope: :channel] when action != :refresh

  plug :rate_limit_refresh when action == :refresh

  action_fallback ConvergerWeb.FallbackController

  tags(["Client: Tokens"])

  operation(:generate,
    summary: "Generate a Converger token",
    description:
      "Exchanges the channel secret (server side) for a short-lived, unscoped Converger token for an end user. `permissions` restricts it (read-only viewers).",
    operation_id: "generateToken",
    security: [%{"channelSecret" => []}],
    request_body: json_schema("Options", ref("ClientTokenRequest")),
    responses:
      with_errors(%{200 => json_schema("The token", ref("ClientToken"))}, [400, 401, 403, 429])
  )

  operation(:refresh,
    summary: "Refresh a Converger token",
    description:
      "A new token with the same claims and a new expiry. The presented token is rotated: it stays valid for the rotation grace period (default 30 s), then is rejected; refreshing it again after that revokes its whole family (`token_revoked`).",
    operation_id: "refreshToken",
    security: [%{"convergerToken" => []}],
    responses:
      with_errors(%{200 => json_schema("The token", ref("ClientToken"))}, [401, 403, 429])
  )

  operation(:revoke,
    summary: "Revoke Converger tokens",
    description:
      "With a token: revokes it and its family (every token derived or refreshed from the same generated token), e.g. on logout. With the channel secret: revokes the `token` given in the body (with its family), or every token of the end user `user.id` issued so far (a banned user). Affected sockets are disconnected; revoked tokens are rejected by every node within a second.",
    operation_id: "revokeToken",
    security: [%{"channelSecret" => []}, %{"convergerToken" => []}],
    request_body: json_schema("What to revoke", ref("ClientTokenRevokeRequest")),
    responses:
      with_errors(
        %{200 => json_schema("Revoked", ref("ClientTokenRevoked"))},
        [400, 401, 403, 429]
      )
  )

  def generate(conn, params) do
    case conn.assigns do
      %{auth_mode: :secret, channel: channel} ->
        scope = params["scope"]

        with :ok <- validate_scope(scope),
             {:ok, permissions} <- ConvergerToken.cast_permissions(params["permissions"]) do
          {:ok, token, claims} =
            ConvergerToken.generate_token(channel,
              user_id: get_in(params, ["user", "id"]),
              scope: scope,
              permissions: permissions
            )

          conn
          |> put_status(:ok)
          |> json(token_body(token, claims))
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
        case ConvergerToken.refresh_claims(claims) do
          {:ok, token, new_claims} ->
            conn
            |> put_status(:ok)
            |> json(token_body(token, new_claims))

          {:error, :token_reused} ->
            # Someone else refreshed this token before: drop every connection
            # of the family's subject too.
            Sockets.disconnect_claims(claims)

            {:error,
             APIError.new(
               :token_revoked,
               "Token was already refreshed; its family is revoked, generate a new token"
             )}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  def revoke(conn, params) do
    case conn.assigns do
      %{auth_mode: :token, converger_claims: claims} ->
        revoke_family(conn, claims)

      %{auth_mode: :secret, channel: channel} ->
        revoke_for_channel(conn, channel, params)

      _ ->
        {:error, :unauthorized}
    end
  end

  defp revoke_for_channel(conn, channel, %{"token" => token}) when is_binary(token) do
    # An expired or already revoked token needs no revocation; a token of
    # another channel is not this secret's to revoke.
    case ConvergerToken.verify_token(token, allow_rotated: true) do
      {:ok, %{"channel_id" => channel_id} = claims} when channel_id == channel.id ->
        revoke_family(conn, claims)

      {:ok, _claims} ->
        {:error, :forbidden}

      {:error, _reason} ->
        conn |> put_status(:ok) |> json(%{revoked: "token"})
    end
  end

  defp revoke_for_channel(conn, channel, %{"user" => %{"id" => user_id}})
       when is_binary(user_id) and user_id != "" do
    :ok = Revocations.revoke_user(channel.tenant_id, channel.id, user_id)
    Sockets.disconnect_user(channel.tenant_id, user_id)

    conn |> put_status(:ok) |> json(%{revoked: "user"})
  end

  defp revoke_for_channel(_conn, _channel, _params),
    do: {:error, "Give the token to revoke, or user.id to revoke all of a user's tokens"}

  defp revoke_family(conn, claims) do
    case Revocations.revoke_family(claims) do
      :ok ->
        Sockets.disconnect_claims(claims)
        conn |> put_status(:ok) |> json(%{revoked: "token"})

      {:error, :not_revocable} ->
        {:error, "Token has no jti and cannot be revoked; it expires on its own"}
    end
  end

  defp rate_limit_refresh(conn, _opts) do
    bucket =
      case conn.assigns[:converger_claims] do
        %{"src" => "publishable"} -> :publishable_token
        _ -> :token_generate
      end

    RateLimit.call(
      conn,
      RateLimit.init(bucket: bucket, scope: :channel)
    )
  end

  defp validate_scope(nil), do: :ok

  defp validate_scope(scope) do
    if scope in ConvergerToken.scopes(),
      do: :ok,
      else: {:error, "scope must be one of: #{Enum.join(ConvergerToken.scopes(), ", ")}"}
  end

  defp token_body(token, claims) do
    %{
      conversationId: claims["conversation_id"],
      token: token,
      expires_in: max(claims["exp"] - Joken.current_time(), 0),
      permissions: claims["perms"]
    }
  end
end
