defmodule ConvergerWeb.Plugs.TenantAuth do
  @moduledoc """
  Authenticates tenant API requests via the `x-api-key` header or a channel
  token in `x-channel-token`. Only channel tokens are accepted there (end-user
  tokens share the signer); channel tokens are deprecated (#23) and each use
  is logged by `ConvergerWeb.Deprecation`.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Converger.Auth.Token
  alias Converger.{Channels, Tenants}

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      api_key = List.first(get_req_header(conn, "x-api-key")) ->
        authenticate_api_key(conn, api_key)

      token = List.first(get_req_header(conn, "x-channel-token")) ->
        authenticate_token(conn, token)

      true ->
        unauthorized(conn, "Missing authentication headers")
    end
  end

  defp authenticate_api_key(conn, api_key) do
    case Tenants.get_tenant_by_api_key(api_key) do
      %Tenants.Tenant{status: "active"} = tenant ->
        assign(conn, :tenant, tenant)

      _ ->
        unauthorized(conn, "Invalid or inactive API Key")
    end
  end

  # Only channel tokens (Converger.Auth.Token.generate_channel_token/1) are
  # tenant credentials. Every token type shares one signer, so the claims
  # must be checked: conversation tokens and Converger client tokens (held by
  # end-user browsers) also carry a `tenant_id` and must never unlock the
  # tenant API.
  defp authenticate_token(conn, token) do
    with {:ok, claims} <- Token.verify_token(token),
         {:ok, channel_id, tenant_id} <- Token.channel_token_claims(claims),
         {:ok, _channel} <- Channels.get_active_channel(channel_id, tenant_id),
         %Tenants.Tenant{status: "active"} = tenant <- Tenants.get_tenant(tenant_id) do
      conn
      |> assign(:tenant, tenant)
      |> ConvergerWeb.Deprecation.mark(:channel_token, tenant_id: tenant.id)
    else
      %Tenants.Tenant{} -> unauthorized(conn, "Tenant is not active")
      {:error, :channel_inactive} -> unauthorized(conn, "Channel is not active")
      _ -> unauthorized(conn, "Invalid token")
    end
  end

  defp unauthorized(conn, message) do
    require Logger
    Logger.warning("Authentication failure: #{message}")

    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Unauthorized: #{message}"})
    |> halt()
  end
end
