defmodule ConvergerWeb.RoutingRuleController do
  use ConvergerWeb, :controller

  alias Converger.RoutingRules

  plug ConvergerWeb.Plugs.TenantAuth

  action_fallback ConvergerWeb.FallbackController

  def index(conn, _params) do
    tenant = conn.assigns.tenant
    rules = RoutingRules.list_routing_rules_for_tenant(tenant.id)
    render(conn, :index, routing_rules: rules)
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant
    rule = RoutingRules.get_routing_rule!(id, tenant.id)
    render(conn, :show, routing_rule: rule)
  end

  def create(conn, %{"routing_rule" => params}) do
    tenant = conn.assigns.tenant
    attrs = Map.put(params, "tenant_id", tenant.id)

    case RoutingRules.create_routing_rule(attrs) do
      {:ok, rule} ->
        conn
        |> put_status(:created)
        |> render(:show, routing_rule: rule)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update(conn, %{"id" => id, "routing_rule" => params}) do
    tenant = conn.assigns.tenant
    rule = RoutingRules.get_routing_rule!(id, tenant.id)

    case RoutingRules.update_routing_rule(rule, params) do
      {:ok, rule} -> render(conn, :show, routing_rule: rule)
      {:error, changeset} -> {:error, changeset}
    end
  end

  def delete(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant
    rule = RoutingRules.get_routing_rule!(id, tenant.id)

    {:ok, _} = RoutingRules.delete_routing_rule(rule)
    send_resp(conn, :no_content, "")
  end
end
