defmodule ConvergerWeb.Plugs.TenantAuth do
  import Plug.Conn
  import Phoenix.Controller

  alias Converger.Tenants

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

  defp authenticate_token(conn, token) do
    case Converger.Auth.Token.verify_token(token) do
      {:ok, %{"tenant_id" => tenant_id}} ->
        case Tenants.get_tenant!(tenant_id) do
          %Tenants.Tenant{status: "active"} = tenant ->
            assign(conn, :tenant, tenant)

          _ ->
            unauthorized(conn, "Tenant is not active")
        end

      {:error, _reason} ->
        unauthorized(conn, "Invalid token")
    end
  rescue
    Ecto.NoResultsError -> unauthorized(conn, "Tenant not found")
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
