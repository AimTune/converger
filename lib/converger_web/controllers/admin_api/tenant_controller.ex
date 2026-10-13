defmodule ConvergerWeb.AdminAPI.TenantController do
  @moduledoc """
  Platform tenant management (ADR-0061): `/api/v1/admin/tenants`.

  Authenticated with `ADMIN_API_TOKEN` behind the admin IP allowlist
  (`ConvergerWeb.Plugs.AdminApiAuth`). Create and `rotate_api_key` return
  the tenant's primary API key, once. Responses carry an `ETag`; `PUT`,
  `PATCH` and `DELETE` honour `If-Match`.
  """
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Tenants
  alias Converger.Tenants.Tenant
  alias ConvergerWeb.ETag

  plug :put_view, json: ConvergerWeb.TenantJSON

  action_fallback ConvergerWeb.FallbackController

  tags(["Admin"])
  security([%{"adminToken" => []}])

  @writable ~w(name status tier retention_days alert_webhook_url allowed_upload_types limits)

  operation(:index,
    summary: "List tenants",
    description: "Not paginated: every tenant, sorted by name, capped at `lookup_limit`.",
    operation_id: "adminListTenants",
    responses: with_errors(%{200 => json_schema("Tenants", ref("TenantList"))}, [401, 403])
  )

  def index(conn, _params), do: render(conn, :index, tenants: Tenants.list_tenants())

  operation(:show,
    summary: "Get a tenant",
    operation_id: "adminGetTenant",
    parameters: [id: path_id("Tenant id")],
    responses:
      with_errors(%{200 => json_schema("The tenant", ref("TenantResponse"))}, [401, 403, 404])
  )

  def show(conn, %{"id" => id}) do
    with {:ok, tenant} <- fetch(id) do
      conn |> ETag.put_etag(tenant) |> render(:show, tenant: tenant)
    end
  end

  operation(:create,
    summary: "Create a tenant",
    description:
      "The response is the only one, besides rotate_api_key, with the primary `api_key`.",
    operation_id: "adminCreateTenant",
    request_body: json_schema("The tenant", ref("TenantRequest")),
    responses:
      with_errors(
        %{201 => json_schema("Created", ref("TenantWithApiKeyResponse"))},
        [400, 401, 403, 422]
      )
  )

  def create(conn, %{"tenant" => params}) when is_map(params) do
    {limits, attrs} = params |> Map.take(@writable) |> Map.pop("limits")
    actor = conn.assigns.admin_actor

    with :ok <- Tenants.validate_limits(limits),
         {:ok, tenant} <- Tenants.create_tenant(attrs, actor),
         {:ok, tenant} <- apply_limits(tenant, limits, actor) do
      conn
      |> put_status(:created)
      |> ETag.put_etag(tenant)
      |> render(:show, tenant: tenant, include_api_key: true)
    end
  end

  def create(_conn, _params), do: {:error, "tenant object is required"}

  operation(:update,
    summary: "Update a tenant",
    description:
      "`limits`, when given, replaces every override. Setting `status` to `inactive` blocks the tenant's API keys. Honours `If-Match`.",
    operation_id: "adminUpdateTenant",
    parameters: [id: path_id("Tenant id")],
    request_body: json_schema("Fields to change", ref("TenantRequest")),
    responses:
      with_errors(
        %{200 => json_schema("Updated", ref("TenantResponse"))},
        [400, 401, 403, 404, 412, 422]
      )
  )

  def update(conn, %{"id" => id, "tenant" => params}) when is_map(params) do
    with {:ok, tenant} <- fetch(id),
         :ok <- ETag.check_if_match(conn, tenant),
         {:ok, tenant} <-
           Tenants.update_tenant_and_limits(
             tenant,
             Map.take(params, @writable),
             conn.assigns.admin_actor
           ) do
      conn |> ETag.put_etag(tenant) |> render(:show, tenant: tenant)
    end
  end

  def update(_conn, _params), do: {:error, "tenant object is required"}

  operation(:delete,
    summary: "Delete a tenant",
    description:
      "Deletes the tenant with its channels, conversations, users and keys; activities and deliveries are purged in the background. Honours `If-Match`.",
    operation_id: "adminDeleteTenant",
    parameters: [id: path_id("Tenant id")],
    responses: with_errors(%{204 => "Deleted"}, [401, 403, 404, 412])
  )

  def delete(conn, %{"id" => id}) do
    with {:ok, tenant} <- fetch(id),
         :ok <- ETag.check_if_match(conn, tenant),
         {:ok, _} <- Tenants.delete_tenant(tenant, conn.assigns.admin_actor) do
      send_resp(conn, :no_content, "")
    end
  end

  operation(:rotate_api_key,
    summary: "Rotate a tenant's primary API key",
    description:
      "Issues a new primary key, returned once. The old key keeps working for the rotation grace period (24 h by default). Scoped keys are not affected.",
    operation_id: "adminRotateTenantApiKey",
    parameters: [tenant_id: path_id("Tenant id")],
    responses:
      with_errors(
        %{200 => json_schema("The new key", ref("TenantWithApiKeyResponse"))},
        [401, 403, 404]
      )
  )

  def rotate_api_key(conn, %{"tenant_id" => id}) do
    with {:ok, tenant} <- fetch(id),
         {:ok, tenant} <- Tenants.rotate_api_key(tenant, actor: conn.assigns.admin_actor) do
      conn |> ETag.put_etag(tenant) |> render(:show, tenant: tenant, include_api_key: true)
    end
  end

  defp apply_limits(tenant, nil, _actor), do: {:ok, tenant}

  defp apply_limits(tenant, limits, actor),
    do: Tenants.update_tenant_and_limits(tenant, %{"limits" => limits}, actor)

  defp fetch(id) do
    case Tenants.get_tenant(id) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :not_found}
    end
  end
end
