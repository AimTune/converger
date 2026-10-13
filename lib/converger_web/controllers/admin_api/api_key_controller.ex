defmodule ConvergerWeb.AdminAPI.ApiKeyController do
  @moduledoc """
  Scoped API key issuance for any tenant (ADR-0061):
  `/api/v1/admin/tenants/:tenant_id/api_keys`. Authenticated with
  `ADMIN_API_TOKEN` (`ConvergerWeb.Plugs.AdminApiAuth`). `DELETE` revokes.
  """
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.{ApiKeys, Tenants}
  alias Converger.ApiKeys.ApiKey
  alias Converger.Tenants.Tenant

  plug :put_view, json: ConvergerWeb.ApiKeyJSON

  action_fallback ConvergerWeb.FallbackController

  tags(["Admin"])
  security([%{"adminToken" => []}])

  operation(:index,
    summary: "List a tenant's API keys",
    description: "Scoped keys, revoked ones included, newest first. Not paginated.",
    operation_id: "adminListApiKeys",
    parameters: [tenant_id: path_id("Tenant id")],
    responses: with_errors(%{200 => json_schema("API keys", ref("ApiKeyList"))}, [401, 403, 404])
  )

  def index(conn, %{"tenant_id" => tenant_id}) do
    with {:ok, tenant} <- fetch_tenant(tenant_id) do
      render(conn, :index, api_keys: ApiKeys.list_api_keys(tenant.id))
    end
  end

  operation(:create,
    summary: "Issue an API key for a tenant",
    description: "The response is the only one with the `key`.",
    operation_id: "adminCreateApiKey",
    parameters: [tenant_id: path_id("Tenant id")],
    request_body: json_schema("The key", ref("CreateApiKeyRequest")),
    responses:
      with_errors(
        %{201 => json_schema("Created", ref("ApiKeyWithKeyResponse"))},
        [400, 401, 403, 404, 422]
      )
  )

  def create(conn, %{"tenant_id" => tenant_id, "api_key" => params}) when is_map(params) do
    with {:ok, tenant} <- fetch_tenant(tenant_id),
         {:ok, api_key} <- ApiKeys.create_api_key(tenant.id, params, conn.assigns.admin_actor) do
      conn
      |> put_status(:created)
      |> render(:show, api_key: api_key, include_key: true)
    end
  end

  def create(_conn, _params), do: {:error, "api_key object is required"}

  operation(:delete,
    summary: "Revoke a tenant's API key",
    description: "The key stops working at once; it stays listed with `revoked_at`.",
    operation_id: "adminRevokeApiKey",
    parameters: [tenant_id: path_id("Tenant id"), id: path_id("API key id")],
    responses: with_errors(%{204 => "Revoked"}, [401, 403, 404])
  )

  def delete(conn, %{"tenant_id" => tenant_id, "id" => id}) do
    with {:ok, tenant} <- fetch_tenant(tenant_id),
         %ApiKey{} = api_key <- ApiKeys.get_api_key(tenant.id, id),
         {:ok, _} <- ApiKeys.revoke_api_key(api_key, conn.assigns.admin_actor) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch_tenant(id) do
    case Tenants.get_tenant(id) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :not_found}
    end
  end
end
