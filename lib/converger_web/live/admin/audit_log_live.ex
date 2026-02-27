defmodule ConvergerWeb.Admin.AuditLogLive do
  use ConvergerWeb, :live_view

  alias Converger.AuditLogs
  alias Converger.Tenants

  @per_page 50

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       tenants: Tenants.list_tenants(),
       filters: %{
         "tenant_id" => "",
         "actor_type" => "",
         "action" => "",
         "resource_type" => ""
       },
       page: 0,
       page_title: "Audit Logs"
     )}
  end

  def handle_params(params, _url, socket) do
    filters =
      Map.merge(
        socket.assigns.filters,
        Map.take(params, ~w(tenant_id actor_type action resource_type))
      )

    page = String.to_integer(Map.get(params, "page", "0"))

    audit_logs = AuditLogs.list_audit_logs(filters, limit: @per_page, offset: page * @per_page)
    total = AuditLogs.count_audit_logs(filters)

    {:noreply,
     assign(socket,
       audit_logs: audit_logs,
       filters: filters,
       page: page,
       total: total,
       total_pages: max(ceil(total / @per_page), 1)
     )}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/audit_logs?#{filters}")}
  end

  def handle_event("prev_page", _, socket) do
    page = max(0, socket.assigns.page - 1)
    params = Map.put(socket.assigns.filters, "page", to_string(page))
    {:noreply, push_patch(socket, to: ~p"/admin/audit_logs?#{params}")}
  end

  def handle_event("next_page", _, socket) do
    page = min(socket.assigns.total_pages - 1, socket.assigns.page + 1)
    params = Map.put(socket.assigns.filters, "page", to_string(page))
    {:noreply, push_patch(socket, to: ~p"/admin/audit_logs?#{params}")}
  end

  defp action_badge_class("create"), do: "active"
  defp action_badge_class("delete"), do: "inactive"
  defp action_badge_class(_), do: ""

  defp format_timestamp(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp truncate_id(id) when is_binary(id), do: String.slice(id, 0..7) <> "..."
  defp truncate_id(_), do: "-"

  def render(assigns) do
    ~H"""
    <h1>Audit Logs</h1>

    <div class="card" style="margin-bottom: 20px;">
      <form phx-change="filter" id="audit-filter-form">
        <div style="display: flex; gap: 15px; align-items: flex-end; flex-wrap: wrap;">
          <div style="margin-bottom: 0;">
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">Tenant</label>
            <select name="filters[tenant_id]" style="padding: 6px; border: 1px solid #ddd; border-radius: 4px;">
              <option value="">All Tenants</option>
              <option :for={t <- @tenants} value={t.id} selected={@filters["tenant_id"] == t.id}>
                <%= t.name %>
              </option>
            </select>
          </div>

          <div style="margin-bottom: 0;">
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">Actor Type</label>
            <select name="filters[actor_type]" style="padding: 6px; border: 1px solid #ddd; border-radius: 4px;">
              <option value="">All Actors</option>
              <option value="admin" selected={@filters["actor_type"] == "admin"}>Admin</option>
              <option value="tenant_api" selected={@filters["actor_type"] == "tenant_api"}>Tenant API</option>
              <option value="system" selected={@filters["actor_type"] == "system"}>System</option>
            </select>
          </div>

          <div style="margin-bottom: 0;">
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">Action</label>
            <select name="filters[action]" style="padding: 6px; border: 1px solid #ddd; border-radius: 4px;">
              <option value="">All Actions</option>
              <option :for={a <- ~w(create update delete toggle_status toggle_enabled)} value={a} selected={@filters["action"] == a}>
                <%= a %>
              </option>
            </select>
          </div>

          <div style="margin-bottom: 0;">
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">Resource Type</label>
            <select name="filters[resource_type]" style="padding: 6px; border: 1px solid #ddd; border-radius: 4px;">
              <option value="">All Resources</option>
              <option :for={r <- ~w(tenant channel routing_rule)} value={r} selected={@filters["resource_type"] == r}>
                <%= r %>
              </option>
            </select>
          </div>

          <a href={~p"/admin/audit_logs"} style="padding: 6px 12px; background: #6c757d; color: white; border-radius: 4px; text-decoration: none; font-size: 0.9em;">
            Reset
          </a>
        </div>
      </form>
    </div>

    <div class="card">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;">
        <span style="color: #666; font-size: 0.9em;"><%= @total %> entries found</span>
        <div style="display: flex; gap: 8px; align-items: center;">
          <button :if={@page > 0} phx-click="prev_page" style="font-size: 0.85em;">Prev</button>
          <span style="padding: 5px 10px; color: #666; font-size: 0.9em;">Page <%= @page + 1 %> of <%= @total_pages %></span>
          <button :if={@page < @total_pages - 1} phx-click="next_page" style="font-size: 0.85em;">Next</button>
        </div>
      </div>

      <table>
        <thead>
          <tr>
            <th>Time</th>
            <th>Actor</th>
            <th>Action</th>
            <th>Resource</th>
            <th>Resource ID</th>
            <th>Changes</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={log <- @audit_logs}>
            <td style="white-space: nowrap;"><small><%= format_timestamp(log.inserted_at) %></small></td>
            <td>
              <span class="badge"><%= log.actor_type %></span>
              <br />
              <small style="color: #666;"><%= truncate_id(log.actor_id) %></small>
            </td>
            <td><span class={"badge badge-#{action_badge_class(log.action)}"}><%= log.action %></span></td>
            <td><%= log.resource_type %></td>
            <td><small><%= truncate_id(to_string(log.resource_id)) %></small></td>
            <td>
              <details :if={log.changes}>
                <summary style="cursor: pointer; font-size: 0.85em; color: #007bff;">View changes</summary>
                <pre style="font-size: 0.75em; max-height: 200px; overflow: auto; background: #f8f9fa; padding: 8px; border-radius: 4px; margin-top: 5px;"><%= Jason.encode!(log.changes, pretty: true) %></pre>
              </details>
              <span :if={is_nil(log.changes)} style="color: #999; font-size: 0.85em;">-</span>
            </td>
          </tr>
          <tr :if={Enum.empty?(@audit_logs)}>
            <td colspan="6" style="text-align: center; color: #999; padding: 30px;">No audit logs found</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
