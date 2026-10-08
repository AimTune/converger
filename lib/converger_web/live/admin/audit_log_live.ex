defmodule ConvergerWeb.Admin.AuditLogLive do
  use ConvergerWeb, :live_view

  alias Converger.AuditLogs
  alias Converger.Tenants

  @filter_keys ~w(tenant_id actor_type action resource_type)

  # Keyset pagination on (inserted_at, id) with "Load more": unlike OFFSET,
  # every page costs the same however deep, and no COUNT(*) over the whole
  # (append-only, ever-growing) table is needed.
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       tenants: Tenants.list_tenants(),
       filters: default_filters(),
       next_cursor: nil,
       has_more: false,
       loaded_count: 0,
       page_title: "Audit Logs"
     )}
  end

  defp default_filters, do: Map.new(@filter_keys, &{&1, ""})

  def handle_params(params, _url, socket) do
    filters = Map.merge(default_filters(), Map.take(params, @filter_keys))

    {:noreply,
     socket
     |> assign(filters: filters)
     |> load_page(reset: true)}
  end

  defp load_page(socket, reset: reset) do
    cursor = if reset, do: nil, else: socket.assigns.next_cursor

    page =
      case AuditLogs.paginate_audit_logs(socket.assigns.filters, cursor: cursor) do
        {:ok, page} -> page
        {:error, :invalid_cursor} -> %Converger.Pagination.Page{}
      end

    loaded = if reset, do: 0, else: socket.assigns.loaded_count

    socket
    |> stream(:audit_logs, page.entries, reset: reset)
    |> assign(
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      loaded_count: loaded + length(page.entries)
    )
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/admin/audit_logs?#{Map.take(filters, @filter_keys)}")}
  end

  def handle_event("load_more", _, socket) do
    if socket.assigns.has_more do
      {:noreply, load_page(socket, reset: false)}
    else
      {:noreply, socket}
    end
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
        <tbody id="audit-logs" phx-update="stream">
          <tr :for={{dom_id, log} <- @streams.audit_logs} id={dom_id}>
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
        </tbody>
      </table>
      <p :if={@loaded_count == 0} style="text-align: center; color: #999; padding: 30px;">No audit logs found</p>
      <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 10px;">
        <span style="color: #666; font-size: 0.9em;">Showing <%= @loaded_count %> entries</span>
        <button :if={@has_more} id="load-more-audit-logs" phx-click="load_more" style="font-size: 0.85em;">Load more</button>
      </div>
    </div>
    """
  end
end
