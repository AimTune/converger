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
    {:noreply, push_patch(socket, to: ~p"/admin/audit_logs?#{Map.take(filters, @filter_keys)}")}
  end

  def handle_event("load_more", _, socket) do
    if socket.assigns.has_more do
      {:noreply, load_page(socket, reset: false)}
    else
      {:noreply, socket}
    end
  end

  defp action_badge_class("create"), do: "badge-success"
  defp action_badge_class("delete"), do: "badge-error"
  defp action_badge_class(_), do: "badge-ghost"

  defp format_timestamp(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp truncate_id(id) when is_binary(id), do: String.slice(id, 0..7) <> "..."
  defp truncate_id(_), do: "-"

  defp tenant_options(tenants), do: [{"All Tenants", ""} | Enum.map(tenants, &{&1.name, &1.id})]

  @actor_type_options [
    {"All Actors", ""},
    {"Admin", "admin"},
    {"Tenant API", "tenant_api"},
    {"System", "system"}
  ]

  @action_options [{"All Actions", ""}] ++
                    Enum.map(
                      ~w(create update delete toggle_status toggle_enabled rotate_api_key),
                      &{&1, &1}
                    )

  @resource_type_options [{"All Resources", ""}] ++
                           Enum.map(~w(tenant channel routing_rule), &{&1, &1})

  def render(assigns) do
    assigns =
      assign(assigns,
        actor_type_options: @actor_type_options,
        action_options: @action_options,
        resource_type_options: @resource_type_options
      )

    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Audit Logs
        <:subtitle>Who changed what, across tenants, channels and routing rules.</:subtitle>
      </.header>

      <.panel title="Filters">
        <form phx-change="filter" id="audit-filter-form">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
            <.input
              type="select"
              id="audit-filter-tenant"
              name="filters[tenant_id]"
              label="Tenant"
              value={@filters["tenant_id"]}
              options={tenant_options(@tenants)}
            />
            <.input
              type="select"
              id="audit-filter-actor-type"
              name="filters[actor_type]"
              label="Actor Type"
              value={@filters["actor_type"]}
              options={@actor_type_options}
            />
            <.input
              type="select"
              id="audit-filter-action"
              name="filters[action]"
              label="Action"
              value={@filters["action"]}
              options={@action_options}
            />
            <.input
              type="select"
              id="audit-filter-resource-type"
              name="filters[resource_type]"
              label="Resource Type"
              value={@filters["resource_type"]}
              options={@resource_type_options}
            />
          </div>
          <.button href={~p"/admin/audit_logs"} size="sm" variant="ghost">
            <.icon name="hero-x-mark" class="size-4" /> Reset
          </.button>
        </form>
      </.panel>

      <.panel>
        <div class="overflow-x-auto">
          <.table id="audit-logs" rows={@streams.audit_logs}>
            <:col :let={{_id, log}} label="Time">
              <span class="whitespace-nowrap text-xs">{format_timestamp(log.inserted_at)}</span>
            </:col>
            <:col :let={{_id, log}} label="Actor">
              <.badge value={log.actor_type} />
              <span class="block font-mono text-xs text-base-content/60">
                {truncate_id(log.actor_id)}
              </span>
            </:col>
            <:col :let={{_id, log}} label="Action">
              <span class={["badge badge-sm whitespace-nowrap", action_badge_class(log.action)]}>
                {log.action}
              </span>
            </:col>
            <:col :let={{_id, log}} label="Resource">{log.resource_type}</:col>
            <:col :let={{_id, log}} label="Resource ID">
              <span class="font-mono text-xs">{truncate_id(to_string(log.resource_id))}</span>
            </:col>
            <:col :let={{_id, log}} label="Changes">
              <details :if={log.changes}>
                <summary class="cursor-pointer text-xs link link-primary">View changes</summary>
                <pre class="mt-1 bg-base-200 rounded-box p-3 text-xs overflow-auto max-h-60">{Jason.encode!(log.changes, pretty: true)}</pre>
              </details>
              <span :if={is_nil(log.changes)} class="text-xs text-base-content/40">-</span>
            </:col>
          </.table>
        </div>
        <.empty_state :if={@loaded_count == 0}>No audit logs found</.empty_state>
        <div class="flex items-center justify-between gap-2">
          <span class="text-sm text-base-content/60">Showing {@loaded_count} entries</span>
          <.button
            :if={@has_more}
            id="load-more-audit-logs"
            phx-click="load_more"
            size="sm"
            variant="neutral"
          >
            Load more
          </.button>
        </div>
      </.panel>
    </Layouts.app>
    """
  end
end
