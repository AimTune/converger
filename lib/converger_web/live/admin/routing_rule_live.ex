defmodule ConvergerWeb.Admin.RoutingRuleLive do
  use ConvergerWeb, :live_view

  alias Converger.Channels
  alias Converger.RoutingRules
  alias Converger.RoutingRules.RoutingRule
  alias Converger.Tenants

  @conditions_placeholder ~s({"all": [{"field": "metadata.vip", "op": "eq", "value": true}]})
  @transformations_placeholder ~s([{"type": "add_prefix", "prefix": "[VIP] "}])

  @filter_keys ~w(q enabled tenant_id sort)
  @list_preloads [:tenant, :source_channel]

  # Admin `viewer`s browse only (docs/security/overview.md).
  @read_only_events ~w(filter load_more)
  @manager_roles ~w(super_admin admin)

  def mount(_params, _session, socket) do
    tenants = Tenants.list_tenants()
    channels = Channels.list_channels()
    actor = build_actor(socket)

    {:ok,
     socket
     |> assign(
       tenants: tenants,
       channels: channels,
       page_title: "Routing Rules",
       can_manage: socket.assigns[:admin_role] in @manager_roles,
       actor: actor,
       filters: default_filters(),
       next_cursor: nil,
       has_more: false,
       loaded_count: 0
     )
     |> stream_configure(:routing_rules, dom_id: &"rule-#{&1.id}")
     |> stream(:routing_rules, [])
     |> reset_form()}
  end

  defp default_filters, do: %{"q" => "", "enabled" => "", "tenant_id" => "", "sort" => "desc"}

  def handle_params(params, _url, socket) do
    filters = Map.merge(default_filters(), Map.take(params, @filter_keys))
    {:noreply, socket |> assign(filters: filters) |> load_rules(reset: true)}
  end

  # Keyset page of rules; `reset: true` starts over (filter change, create).
  defp load_rules(socket, reset: reset) do
    filters = socket.assigns.filters
    cursor = if reset, do: nil, else: socket.assigns.next_cursor

    page =
      case RoutingRules.paginate_routing_rules(Map.take(filters, ~w(q enabled tenant_id)),
             cursor: cursor,
             direction: if(filters["sort"] == "asc", do: :asc, else: :desc),
             preload: @list_preloads
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

  # Re-render a changed row, or drop it when it no longer matches the
  # enabled filter (e.g. disabled while listing enabled rules).
  defp refresh_rule(socket, rule) do
    if socket.assigns.filters["enabled"] in ["true", "false"] and
         to_string(rule.enabled) != socket.assigns.filters["enabled"] do
      socket
      |> stream_delete(:routing_rules, rule)
      |> assign(loaded_count: max(socket.assigns.loaded_count - 1, 0))
    else
      stream_insert(socket, :routing_rules, Converger.Repo.preload(rule, @list_preloads))
    end
  end

  defp reset_form(socket) do
    assign(socket,
      editing: nil,
      filtered_channels: [],
      source_candidates: [],
      target_candidates: [],
      selected_tenant_id: nil,
      selected_source_channel_id: nil,
      selected_target_ids: [],
      conditions_json: "",
      transformations_json: "",
      form: to_form(RoutingRules.change_routing_rule(%RoutingRule{}))
    )
  end

  def handle_event(event, _params, %{assigns: %{can_manage: false}} = socket)
      when event not in @read_only_events do
    {:noreply, put_flash(socket, :error, "Viewers have read-only access to routing rules.")}
  end

  def handle_event("form_changed", %{"routing_rule" => params}, socket) do
    tenant_id = params["tenant_id"] || socket.assigns.selected_tenant_id || ""

    {:noreply,
     socket
     |> select_tenant(tenant_id, params["source_channel_id"] || "")
     |> assign(
       selected_target_ids: target_ids(params),
       conditions_json: params["conditions"] || "",
       transformations_json: params["transformations"] || ""
     )}
  end

  def handle_event("save", %{"routing_rule" => params}, socket) do
    with {:ok, conditions} <- decode_json(params["conditions"], %{}, :conditions),
         {:ok, transformations} <- decode_json(params["transformations"], [], :transformations) do
      params =
        params
        |> Map.put("target_channel_ids", target_ids(params))
        |> Map.put("conditions", conditions)
        |> Map.put("transformations", transformations)
        |> Map.put_new("stop_processing", "false")

      socket = assign(socket, conditions_json: params_json(params, "conditions"))
      save(socket, socket.assigns.editing, params)
    else
      {:error, field, message} ->
        changeset =
          socket.assigns.form.source
          |> Ecto.Changeset.add_error(field, message)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    rule = RoutingRules.get_routing_rule!(id)

    {:noreply,
     socket
     |> select_tenant(rule.tenant_id, rule.source_channel_id)
     |> assign(
       editing: rule,
       selected_target_ids: rule.target_channel_ids,
       conditions_json: encode_json(rule.conditions, %{}),
       transformations_json: encode_json(rule.transformations, []),
       form: to_form(RoutingRules.change_routing_rule(rule))
     )}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, reset_form(socket)}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    query = filters |> Map.take(@filter_keys) |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
    {:noreply, push_patch(socket, to: "/admin/routing_rules?#{URI.encode_query(query)}")}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more,
      do: {:noreply, load_rules(socket, reset: false)},
      else: {:noreply, socket}
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    rule = RoutingRules.get_routing_rule!(id)

    case RoutingRules.toggle_routing_rule(rule, socket.assigns.actor) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> refresh_rule(updated)
         |> put_flash(:info, "Rule toggled")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle rule")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    rule = RoutingRules.get_routing_rule!(id)

    case RoutingRules.delete_routing_rule(rule, socket.assigns.actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> stream_delete(:routing_rules, rule)
         |> assign(loaded_count: max(socket.assigns.loaded_count - 1, 0))
         |> put_flash(:info, "Rule deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete rule")}
    end
  end

  defp save(socket, nil, params) do
    case RoutingRules.create_routing_rule(params, socket.assigns.actor) do
      {:ok, _rule} ->
        # Reload the first page so the new rule lands where the sort puts it.
        {:noreply, socket |> load_rules(reset: true) |> saved("Routing rule created")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, %RoutingRule{} = rule, params) do
    params = Map.drop(params, ["tenant_id"])

    case RoutingRules.update_routing_rule(rule, params, socket.assigns.actor) do
      {:ok, updated} ->
        {:noreply, socket |> refresh_rule(updated) |> saved("Routing rule updated")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp saved(socket, message) do
    socket
    |> put_flash(:info, message)
    |> reset_form()
  end

  defp select_tenant(socket, tenant_id, source_channel_id) do
    filtered =
      if tenant_id in [nil, ""],
        do: [],
        else: Enum.filter(socket.assigns.channels, &(&1.tenant_id == tenant_id))

    source_candidates = Enum.filter(filtered, &(&1.mode in ["inbound", "duplex"]))
    target_candidates = Enum.filter(filtered, &(&1.mode in ["outbound", "duplex"]))

    source_id =
      if source_channel_id not in [nil, ""] and
           Enum.any?(source_candidates, &(&1.id == source_channel_id)),
         do: source_channel_id

    assign(socket,
      filtered_channels: filtered,
      source_candidates: source_candidates,
      target_candidates: target_candidates,
      selected_tenant_id: tenant_id,
      selected_source_channel_id: source_id
    )
  end

  defp target_ids(params) do
    params |> Map.get("target_channel_ids", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
  end

  # Conditions and transformations are edited as JSON text.
  defp decode_json(text, empty, field) do
    case String.trim(text || "") do
      "" ->
        {:ok, empty}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, value} -> {:ok, value}
          {:error, error} -> {:error, field, "is not valid JSON: #{Exception.message(error)}"}
        end
    end
  end

  defp encode_json(value, empty) when value == empty or is_nil(value), do: ""
  defp encode_json(value, _empty), do: Jason.encode!(value, pretty: true)

  defp params_json(params, key), do: encode_json(params[key], %{})

  defp build_actor(socket) do
    case socket.assigns[:current_admin_user] do
      %{email: email} -> %{type: "admin", id: email}
      _ -> %{type: "admin", id: "unknown"}
    end
  end

  defp mode_indicator("inbound"), do: "← Inbound"
  defp mode_indicator("outbound"), do: "→ Outbound"
  defp mode_indicator("duplex"), do: "↔ Duplex"

  defp channel_name(channel_id, channels) do
    case Enum.find(channels, &(&1.id == channel_id)) do
      nil -> String.slice(channel_id, 0..7) <> "..."
      ch -> ch.name
    end
  end

  defp target_channels(filtered_channels, selected_source_channel_id) do
    Enum.reject(filtered_channels, &(&1.id == selected_source_channel_id))
  end

  defp conditions_summary(conditions) when conditions == %{} or is_nil(conditions),
    do: "always"

  defp conditions_summary(conditions), do: Jason.encode!(conditions)

  defp field_errors(form, field) do
    Enum.map(form[field].errors, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
      end)
    end)
  end

  defp placeholder(:conditions), do: @conditions_placeholder
  defp placeholder(:transformations), do: @transformations_placeholder

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Routing Rules
        <:subtitle>
          Route messages from a source channel to target channels, optionally only when conditions match.
          Rules of a source channel run in ascending priority; a matching rule with "stop processing" ends the evaluation.
          Replies written from a target channel go back to the conversation's origin channel.
        </:subtitle>
        <:actions>
          <.button navigate={~p"/admin/routing_rules/dry_run"} size="sm" variant="neutral">
            <.icon name="hero-beaker" /> Dry run an activity
          </.button>
        </:actions>
      </.header>

      <.panel :if={@can_manage} title={if @editing, do: "Edit Routing Rule: #{@editing.name}", else: "Create Routing Rule"}>
        <.form for={@form} id="routing-rule-form" phx-submit="save" phx-change="form_changed">
          <div class="grid items-end gap-x-4 sm:grid-cols-2 lg:grid-cols-5">
            <.input
              type="select"
              id="routing_rule_tenant_id"
              name="routing_rule[tenant_id]"
              label="Tenant"
              prompt="Select Tenant"
              options={Enum.map(@tenants, &{&1.name, &1.id})}
              value={@selected_tenant_id}
              required
              disabled={@editing != nil}
            />
            <.input field={@form[:name]} label="Rule Name" placeholder="e.g. WhatsApp to WebSocket" />
            <.input
              type="select"
              id="routing_rule_source_channel_id"
              name="routing_rule[source_channel_id]"
              label="Source Channel"
              prompt={if @selected_tenant_id, do: "Select Source Channel", else: "Select a tenant first"}
              options={Enum.map(@source_candidates, &{"#{&1.name} (#{&1.type}) #{mode_indicator(&1.mode)}", &1.id})}
              value={@selected_source_channel_id}
              required
            />
            <.input field={@form[:priority]} type="number" label="Priority (lower runs first)" />
            <.input field={@form[:stop_processing]} type="checkbox" label="Stop processing when matched" />
          </div>

          <fieldset
            :if={
              @selected_source_channel_id &&
                target_channels(@target_candidates, @selected_source_channel_id) != []
            }
            class="mt-4 rounded-box border border-base-300 bg-base-200 p-4"
          >
            <legend class="px-1 text-sm font-semibold">Target Channels (outbound/duplex only)</legend>
            <div class="flex flex-wrap gap-2">
              <label
                :for={ch <- target_channels(@target_candidates, @selected_source_channel_id)}
                class="flex cursor-pointer items-center gap-2 rounded-field border border-base-300 bg-base-100 px-3 py-1.5 text-sm"
              >
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  name="routing_rule[target_channel_ids][]"
                  value={ch.id}
                  checked={ch.id in @selected_target_ids}
                />
                {ch.name}
                <span class="text-xs text-base-content/60">
                  ({ch.type}) {mode_indicator(ch.mode)}
                </span>
              </label>
            </div>
            <.error :for={message <- field_errors(@form, :target_channel_ids)}>{message}</.error>
          </fieldset>

          <div
            :if={
              @selected_source_channel_id &&
                target_channels(@target_candidates, @selected_source_channel_id) == []
            }
            role="alert"
            class="alert alert-warning mt-4 text-sm"
          >
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>No outbound-capable channels available for this tenant. Create more channels first.</span>
          </div>

          <div class="mt-4 grid gap-x-4 md:grid-cols-2">
            <.input
              :for={
                {field, label} <- [
                  conditions: "Conditions (JSON, empty = every activity)",
                  transformations: "Rule transformations (JSON middleware chain)"
                ]
              }
              type="textarea"
              id={"routing_rule_#{field}"}
              name={"routing_rule[#{field}]"}
              label={label}
              rows="6"
              placeholder={placeholder(field)}
              class="textarea w-full font-mono text-xs"
              value={if field == :conditions, do: @conditions_json, else: @transformations_json}
              errors={field_errors(@form, field)}
            />
          </div>
          <p class="text-xs text-base-content/60">
            Fields: type, sender, text, metadata.*, conversation.metadata.*, conversation.status,
            participant.external_id, participant.display_name, participant.metadata.*, time.hour,
            time.minute, time.minute_of_day, time.weekday, time.date. Ops: eq, neq, in, contains, regex, exists, gt, lt.
            Groups: all, any, not.
          </p>

          <div class="mt-4 flex gap-2">
            <.button type="submit" variant="primary">
              {if @editing, do: "Save Rule", else: "Create Rule"}
            </.button>
            <.button :if={@editing} type="button" phx-click="cancel_edit" variant="ghost">
              Cancel
            </.button>
          </div>
        </.form>
      </.panel>

      <.panel title="Existing Rules">
        <form id="routing-rule-filter" phx-change="filter">
          <div class="grid items-end gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
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
              id="rule_filters_tenant_id"
              name="filters[tenant_id]"
              value={@filters["tenant_id"]}
              label="Tenant"
              prompt="All Tenants"
              options={Enum.map(@tenants, &{&1.name, &1.id})}
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
            <:col :let={rule} label="Tenant">{if rule.tenant, do: rule.tenant.name, else: "-"}</:col>
            <:col :let={rule} label="Source">
              <span class="badge badge-sm badge-info whitespace-nowrap">
                {if rule.source_channel, do: rule.source_channel.name, else: "-"}
              </span>
            </:col>
            <:col :let={rule} label="Targets">
              <div class="flex flex-wrap gap-1">
                <span
                  :for={tid <- rule.target_channel_ids}
                  class="badge badge-sm badge-secondary whitespace-nowrap"
                >
                  {channel_name(tid, @channels)}
                </span>
              </div>
            </:col>
            <:col :let={rule} label="Priority">
              {rule.priority}<span
                :if={rule.stop_processing}
                title="stop processing"
                class="text-base-content/60"
              > (stop)</span>
            </:col>
            <:col :let={rule} label="Conditions">
              <code class="block max-w-72 font-mono text-xs break-all">
                {conditions_summary(rule.conditions)}
              </code>
              <div :if={rule.transformations != []} class="text-xs text-base-content/60">
                {length(rule.transformations)} transformation(s)
              </div>
            </:col>
            <:col :let={rule} label="Status">
              <.badge value={if rule.enabled, do: "enabled", else: "disabled"}>
                {if rule.enabled, do: "Enabled", else: "Disabled"}
              </.badge>
            </:col>
            <:action :let={rule} :if={@can_manage}>
              <div class="flex justify-end gap-1 whitespace-nowrap">
                <.button phx-click="edit" phx-value-id={rule.id} size="xs">Edit</.button>
                <.button phx-click="toggle_enabled" phx-value-id={rule.id} size="xs" variant="neutral">
                  {if rule.enabled, do: "Disable", else: "Enable"}
                </.button>
                <.button
                  phx-click="delete"
                  phx-value-id={rule.id}
                  data-confirm="Are you sure you want to delete this rule?"
                  size="xs"
                  variant="error"
                >
                  Delete
                </.button>
              </div>
            </:action>
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
