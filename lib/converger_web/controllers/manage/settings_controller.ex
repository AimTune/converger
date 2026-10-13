defmodule ConvergerWeb.Manage.SettingsController do
  @moduledoc """
  The tenant's own settings (ADR-0061): `/api/v1/manage/settings`.

  Requires an API key with the `manage` scope. A tenant can change its
  retention, alert webhook URL, allowed upload types and rate-limit
  overrides; its name, status and delivery tier are platform settings
  (`/api/v1/admin/tenants`).
  """
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Tenants
  alias ConvergerWeb.{ETag, Plugs.TenantAuth}

  plug TenantAuth, scope: "manage", api_key_only: true

  plug :put_view, json: ConvergerWeb.TenantJSON

  action_fallback ConvergerWeb.FallbackController

  tags(["Management"])
  security([%{"apiKey" => []}])

  @writable ~w(retention_days alert_webhook_url allowed_upload_types limits)

  operation(:show,
    summary: "Get the tenant's settings",
    operation_id: "manageGetSettings",
    responses: with_errors(%{200 => json_schema("The tenant", ref("TenantResponse"))}, [401, 403])
  )

  def show(conn, _params) do
    tenant = conn.assigns.tenant
    conn |> ETag.put_etag(tenant) |> render(:show, tenant: tenant)
  end

  operation(:update,
    summary: "Update the tenant's settings",
    description: "`limits`, when given, replaces every override. Honours `If-Match`.",
    operation_id: "manageUpdateSettings",
    request_body: json_schema("Settings to change", ref("TenantSettingsRequest")),
    responses:
      with_errors(
        %{200 => json_schema("Updated", ref("TenantResponse"))},
        [400, 401, 403, 412, 422]
      )
  )

  def update(conn, %{"settings" => params}) when is_map(params) do
    tenant = conn.assigns.tenant

    with :ok <- ETag.check_if_match(conn, tenant),
         {:ok, tenant} <-
           Tenants.update_tenant_and_limits(
             tenant,
             Map.take(params, @writable),
             TenantAuth.actor(conn)
           ) do
      conn |> ETag.put_etag(tenant) |> render(:show, tenant: tenant)
    end
  end

  def update(_conn, _params), do: {:error, "settings object is required"}
end
