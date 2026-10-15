defmodule ConvergerWeb.RoutingRuleController do
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.RoutingRules

  # Rule changes are configuration (`manage`); a dry-run only reads (ADR-0061).
  plug ConvergerWeb.Plugs.TenantAuth,
    scopes: [create: "manage", update: "manage", delete: "manage", dry_run: "read"]

  action_fallback ConvergerWeb.FallbackController

  tags(["Routing rules"])
  security([%{"apiKey" => []}, %{"channelToken" => []}])

  operation(:index,
    summary: "List routing rules",
    description: "Not paginated: the whole list, sorted by name, capped at `lookup_limit`.",
    operation_id: "listRoutingRules",
    responses: with_errors(%{200 => json_schema("Routing rules", ref("RoutingRuleList"))}, [401])
  )

  def index(conn, _params) do
    tenant = conn.assigns.tenant
    rules = RoutingRules.list_routing_rules_for_tenant(tenant.id)
    render(conn, :index, routing_rules: rules)
  end

  operation(:show,
    summary: "Get a routing rule",
    operation_id: "getRoutingRule",
    parameters: [id: path_id("Routing rule id")],
    responses:
      with_errors(%{200 => json_schema("The rule", ref("RoutingRuleResponse"))}, [400, 401, 404])
  )

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant
    rule = RoutingRules.get_routing_rule!(id, tenant.id)
    render(conn, :show, routing_rule: rule)
  end

  operation(:create,
    summary: "Create a routing rule",
    operation_id: "createRoutingRule",
    request_body: json_schema("The rule", ref("RoutingRuleRequest")),
    responses:
      with_errors(%{201 => json_schema("Created", ref("RoutingRuleResponse"))}, [400, 401, 422])
  )

  def create(conn, %{"routing_rule" => params}) do
    tenant = conn.assigns.tenant
    attrs = Map.put(params, "tenant_id", tenant.id)

    case RoutingRules.create_routing_rule(attrs, build_actor(conn)) do
      {:ok, rule} ->
        conn
        |> put_status(:created)
        |> render(:show, routing_rule: rule)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  operation(:update,
    summary: "Update a routing rule",
    operation_id: "updateRoutingRule",
    parameters: [id: path_id("Routing rule id")],
    request_body: json_schema("Fields to change", ref("RoutingRuleRequest")),
    responses:
      with_errors(%{200 => json_schema("Updated", ref("RoutingRuleResponse"))}, [
        400,
        401,
        404,
        422
      ])
  )

  def update(conn, %{"id" => id, "routing_rule" => params}) do
    tenant = conn.assigns.tenant
    rule = RoutingRules.get_routing_rule!(id, tenant.id)

    case RoutingRules.update_routing_rule(rule, params, build_actor(conn)) do
      {:ok, rule} -> render(conn, :show, routing_rule: rule)
      {:error, changeset} -> {:error, changeset}
    end
  end

  operation(:delete,
    summary: "Delete a routing rule",
    operation_id: "deleteRoutingRule",
    parameters: [id: path_id("Routing rule id")],
    responses: with_errors(%{204 => "Deleted"}, [400, 401, 404])
  )

  def delete(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant
    rule = RoutingRules.get_routing_rule!(id, tenant.id)

    {:ok, _} = RoutingRules.delete_routing_rule(rule, build_actor(conn))
    send_resp(conn, :no_content, "")
  end

  operation(:dry_run,
    summary: "Dry-run routing",
    description:
      "The matched rules and the payload each target would get, without storing or sending anything.",
    operation_id: "dryRunRouting",
    request_body: json_schema("What to dry-run", ref("DryRunRequest")),
    responses:
      with_errors(%{200 => json_schema("The routing plan", ref("DryRunResponse"))}, [
        400,
        401,
        404,
        422
      ])
  )

  # Dry-run: matched rules and the payload each target would get, without
  # storing or sending anything (Converger.RoutingRules.DryRun).
  def dry_run(conn, params) do
    case RoutingRules.DryRun.run(conn.assigns.tenant.id, Map.drop(params, ["format"])) do
      {:ok, result} ->
        render(conn, :dry_run, result: result)

      {:error, {:bad_request, message}} ->
        {:error, message}

      {:error, _} = error ->
        error
    end
  end

  defp build_actor(conn), do: ConvergerWeb.Plugs.TenantAuth.actor(conn)
end
