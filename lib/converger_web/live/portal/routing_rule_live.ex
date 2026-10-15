defmodule ConvergerWeb.Portal.RoutingRuleLive do
  use ConvergerWeb, :live_view

  alias Converger.Channels
  alias Converger.RoutingRules

  # Keyset-paginated ("Load more") with URL-driven filters, scoped to the
  # current tenant.
  @filter_keys ~w(q enabled sort)

  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.current_tenant.id
    can_edit = socket.assigns.tenant_role in ~w(owner admin member)

    {:ok,
     socket
     |> assign(
       channels: Channels.list_channels_for_tenant(tenant_id),
       page_title: "Routing Rules",
       can_edit: can_edit,
       filters: default_filters(),
       next_cursor: nil,
       has_more: false,
       loaded_count: 0
     )
     |> stream_configure(:routing_rules, dom_id: &"rule-#{&1.id}")
     |> stream(:routing_rules, [])}
  end

  defp default_filters, do: %{"q" => "", "enabled" => "", "sort" => "desc"}

  def handle_params(params, _url, socket) do
    filters = Map.merge(default_filters(), Map.take(params, @filter_keys))
    {:noreply, socket |> assign(filters: filters) |> load_rules(reset: true)}
  end

  defp load_rules(socket, reset: reset) do
    filters = socket.assigns.filters
    cursor = if reset, do: nil, else: socket.assigns.next_cursor

    scope =
      filters
      |> Map.take(~w(q enabled))
      |> Map.put("tenant_id", socket.assigns.current_tenant.id)

    page =
      case RoutingRules.paginate_routing_rules(scope,
             cursor: cursor,
             direction: if(filters["sort"] == "asc", do: :asc, else: :desc)
           ) do
        {:ok, page} -> page
        {:error, :invalid_cursor} -> %Converger.Pagination.Page{}
      end

    loaded = if reset, do: 0, else: socket.assigns.loaded_count

    socket
    |> stream(:routing_rules, page.entries, reset: reset)
    |> assign(
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      loaded_count: loaded + length(page.entries)
    )
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    query = filters |> Map.take(@filter_keys) |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
    {:noreply, push_patch(socket, to: "/portal/routing_rules?#{URI.encode_query(query)}")}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more,
      do: {:noreply, load_rules(socket, reset: false)},
      else: {:noreply, socket}
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    if socket.assigns.can_edit do
      case RoutingRules.get_routing_rule(id, socket.assigns.current_tenant.id) do
        nil -> {:noreply, put_flash(socket, :error, "Unauthorized")}
        rule -> toggle_rule_enabled(socket, rule)
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}
    end
  end

  defp toggle_rule_enabled(socket, rule) do
    case RoutingRules.update_routing_rule(rule, %{enabled: !rule.enabled}, build_actor(socket)) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> refresh_rule(updated)
         |> put_flash(:info, "Rule updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update rule")}
    end
  end

  # Re-render a changed row, or drop it when it no longer matches the
  # enabled filter.
  defp refresh_rule(socket, rule) do
    if socket.assigns.filters["enabled"] in ["true", "false"] and
         to_string(rule.enabled) != socket.assigns.filters["enabled"] do
      socket
      |> stream_delete(:routing_rules, rule)
      |> assign(loaded_count: max(socket.assigns.loaded_count - 1, 0))
    else
      stream_insert(socket, :routing_rules, rule)
    end
  end

  defp build_actor(socket) do
    case socket.assigns[:current_tenant_user] do
      %{email: email} -> %{type: "tenant_user", id: email}
      _ -> %{type: "tenant_user", id: "unknown"}
    end
  end

  defp channel_name(channels, channel_id) do
    case Enum.find(channels, &(&1.id == channel_id)) do
      nil -> "Unknown"
      channel -> channel.name
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Routing Rules
        <:subtitle>Rules that route messages from a source channel to target channels.</:subtitle>
      </.header>

      <.panel>
        <form id="routing-rule-filter" phx-change="filter">
          <div class="grid items-end gap-x-4 sm:grid-cols-3">
            <.input
              type="search"
              id="rule_filters_q"
              name="filters[q]"
              value={@filters["q"]}
              label="Search"
              placeholder="Rule name"
              phx-debounce="300"
            />
            <.input
              type="select"
              id="rule_filters_enabled"
              name="filters[enabled]"
              value={@filters["enabled"]}
              label="Status"
              prompt="All"
              options={[{"Enabled", "true"}, {"Disabled", "false"}]}
            />
            <.input
              type="select"
              id="rule_filters_sort"
              name="filters[sort]"
              value={@filters["sort"]}
              label="Sort"
              options={[{"Newest first", "desc"}, {"Oldest first", "asc"}]}
            />
          </div>
        </form>
        <div class="overflow-x-auto">
          <.table
            id="routing-rules"
            rows={@streams.routing_rules}
            row_item={fn {_dom_id, rule} -> rule end}
          >
            <:col :let={rule} label="Name"><span class="font-medium">{rule.name}</span></:col>
            <:col :let={rule} label="Source Channel">
              {channel_name(@channels, rule.source_channel_id)}
            </:col>
            <:col :let={rule} label="Target Channels">
              <div class="flex flex-wrap gap-1">
                <span
                  :for={target_id <- rule.target_channel_ids}
                  class="badge badge-sm badge-secondary whitespace-nowrap"
                >
                  {channel_name(@channels, target_id)}
                </span>
              </div>
            </:col>
            <:col :let={rule} label="Priority">
              {rule.priority}<span :if={rule.stop_processing} class="text-base-content/60"> (stop)</span>
            </:col>
            <:col :let={rule} label="Conditions">
              <code class="block max-w-72 font-mono text-xs break-all">
                {if rule.conditions == %{}, do: "always", else: Jason.encode!(rule.conditions)}
              </code>
            </:col>
            <:col :let={rule} label="Enabled">
              <.badge value={if rule.enabled, do: "enabled", else: "disabled"} />
            </:col>
            <:col :let={rule} :if={@can_edit} label="Actions">
              <.button phx-click="toggle_enabled" phx-value-id={rule.id} size="xs" variant="neutral">
                {if rule.enabled, do: "Disable", else: "Enable"}
              </.button>
            </:col>
          </.table>
        </div>
        <.empty_state :if={@loaded_count == 0}>No routing rules found.</.empty_state>
        <div class="flex flex-wrap items-center justify-between gap-2">
          <span class="text-sm text-base-content/60">Showing {@loaded_count} rules</span>
          <.button
            :if={@has_more}
            id="load-more-routing-rules"
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
