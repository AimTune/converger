defmodule ConvergerWeb.Admin.RoutingRuleLive do
  use ConvergerWeb, :live_view

  alias Converger.Channels
  alias Converger.RoutingRules
  alias Converger.RoutingRules.RoutingRule
  alias Converger.Tenants

  @conditions_placeholder ~s({"all": [{"field": "metadata.vip", "op": "eq", "value": true}]})
  @transformations_placeholder ~s([{"type": "add_prefix", "prefix": "[VIP] "}])

  def mount(_params, _session, socket) do
    tenants = Tenants.list_tenants()
    channels = Channels.list_channels()
    actor = build_actor(socket)

    {:ok,
     socket
     |> assign(
       routing_rules: RoutingRules.list_routing_rules(),
       tenants: tenants,
       channels: channels,
       page_title: "Routing Rules",
       actor: actor
     )
     |> reset_form()}
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

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    rule = RoutingRules.get_routing_rule!(id)

    case RoutingRules.toggle_routing_rule(rule, socket.assigns.actor) do
      {:ok, _} ->
        {:noreply,
         assign(socket, routing_rules: RoutingRules.list_routing_rules())
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
         assign(socket, routing_rules: RoutingRules.list_routing_rules())
         |> put_flash(:info, "Rule deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete rule")}
    end
  end

  defp save(socket, nil, params) do
    case RoutingRules.create_routing_rule(params, socket.assigns.actor) do
      {:ok, _rule} -> {:noreply, saved(socket, "Routing rule created")}
      {:error, changeset} -> {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, %RoutingRule{} = rule, params) do
    params = Map.drop(params, ["tenant_id"])

    case RoutingRules.update_routing_rule(rule, params, socket.assigns.actor) do
      {:ok, _rule} -> {:noreply, saved(socket, "Routing rule updated")}
      {:error, changeset} -> {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp saved(socket, message) do
    socket
    |> put_flash(:info, message)
    |> assign(routing_rules: RoutingRules.list_routing_rules())
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
    <h1 style="margin-bottom: 5px;">Routing Rules</h1>
    <p style="color: #666; margin-top: 0; margin-bottom: 20px;">
      Route messages from a source channel to target channels, optionally only when conditions match.
      Rules of a source channel run in ascending priority; a matching rule with "stop processing" ends the evaluation.
      Replies written from a target channel go back to the conversation's origin channel.
      <.link navigate={~p"/admin/routing_rules/dry_run"} style="margin-left: 6px;">Dry run an activity</.link>
    </p>

    <div class="card">
      <h3 style="margin-top: 0; margin-bottom: 15px; border-bottom: 1px solid #eee; padding-bottom: 10px;">
        {if @editing, do: "Edit Routing Rule: #{@editing.name}", else: "Create Routing Rule"}
      </h3>
      <.form for={@form} id="routing-rule-form" phx-submit="save" phx-change="form_changed">
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px;">
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              Tenant
            </label>
            <select
              name="routing_rule[tenant_id]"
              required
              disabled={@editing != nil}
              style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; background: #fff;"
            >
              <option value="">Select Tenant</option>
              <%= for tenant <- @tenants do %>
                <option value={tenant.id} selected={@selected_tenant_id == tenant.id}>
                  {tenant.name}
                </option>
              <% end %>
            </select>
          </div>

          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              Rule Name
            </label>
            <.input
              field={@form[:name]}
              placeholder="e.g. WhatsApp to WebSocket"
              style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px;"
            />
          </div>

          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              Source Channel
            </label>
            <select
              name="routing_rule[source_channel_id]"
              required
              style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; background: #fff;"
            >
              <option value="">
                {if @selected_tenant_id, do: "Select Source Channel", else: "Select a tenant first"}
              </option>
              <%= for ch <- @source_candidates do %>
                <option value={ch.id} selected={@selected_source_channel_id == ch.id}>
                  {ch.name} ({ch.type}) {mode_indicator(ch.mode)}
                </option>
              <% end %>
            </select>
          </div>

          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              Priority (lower runs first)
            </label>
            <.input
              field={@form[:priority]}
              type="number"
              style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px;"
            />
          </div>

          <div style="display: flex; align-items: flex-end;">
            <.input field={@form[:stop_processing]} type="checkbox" label="Stop processing when matched" />
          </div>
        </div>

        <div
          :if={
            @selected_source_channel_id &&
              target_channels(@target_candidates, @selected_source_channel_id) != []
          }
          style="margin-top: 20px; padding: 15px; background: #f8f9fa; border-radius: 6px; border: 1px solid #e9ecef;"
        >
          <label style="display: block; font-weight: 600; margin-bottom: 10px; font-size: 0.9em; color: #555;">
            Target Channels (outbound/duplex only)
          </label>
          <div style="display: flex; gap: 12px; flex-wrap: wrap;">
            <%= for ch <- target_channels(@target_candidates, @selected_source_channel_id) do %>
              <label style="display: flex; align-items: center; gap: 6px; padding: 6px 12px; background: #fff; border: 1px solid #ddd; border-radius: 4px; cursor: pointer; font-size: 0.9em;">
                <input
                  type="checkbox"
                  name="routing_rule[target_channel_ids][]"
                  value={ch.id}
                  checked={ch.id in @selected_target_ids}
                />
                {ch.name}
                <span style="color: #888; font-size: 0.85em;">
                  ({ch.type}) {mode_indicator(ch.mode)}
                </span>
              </label>
            <% end %>
          </div>
          <p
            :for={message <- field_errors(@form, :target_channel_ids)}
            style="color: #dc3545; font-size: 0.85em; margin: 6px 0 0;"
          >
            {message}
          </p>
        </div>

        <div
          :if={
            @selected_source_channel_id &&
              target_channels(@target_candidates, @selected_source_channel_id) == []
          }
          style="margin-top: 20px; padding: 15px; background: #fff3cd; border-radius: 6px; border: 1px solid #ffc107; color: #856404; font-size: 0.9em;"
        >
          No outbound-capable channels available for this tenant. Create more channels first.
        </div>

        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 15px; margin-top: 20px;">
          <div :for={{field, label} <- [conditions: "Conditions (JSON, empty = every activity)", transformations: "Rule transformations (JSON middleware chain)"]}>
            <label
              for={"routing_rule_#{field}"}
              style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;"
            >
              {label}
            </label>
            <textarea
              id={"routing_rule_#{field}"}
              name={"routing_rule[#{field}]"}
              rows="6"
              placeholder={placeholder(field)}
              style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; font-family: monospace; font-size: 0.85em;"
            >{if field == :conditions, do: @conditions_json, else: @transformations_json}</textarea>
            <p
              :for={message <- field_errors(@form, field)}
              style="color: #dc3545; font-size: 0.85em; margin: 4px 0 0;"
            >
              {message}
            </p>
          </div>
        </div>
        <p style="color: #888; font-size: 0.8em; margin: 6px 0 0;">
          Fields: type, sender, text, metadata.*, conversation.metadata.*, conversation.status,
          participant.external_id, participant.display_name, participant.metadata.*, time.hour,
          time.minute, time.minute_of_day, time.weekday, time.date. Ops: eq, neq, in, contains, regex, exists, gt, lt.
          Groups: all, any, not.
        </p>

        <button type="submit" style="margin-top: 15px; padding: 8px 20px; font-size: 0.95em;">
          {if @editing, do: "Save Rule", else: "Create Rule"}
        </button>
        <button
          :if={@editing}
          type="button"
          phx-click="cancel_edit"
          style="margin-top: 15px; margin-left: 6px; padding: 8px 20px; font-size: 0.95em; background: #6c757d;"
        >
          Cancel
        </button>
      </.form>
    </div>

    <div class="card">
      <h3 style="margin-top: 0; margin-bottom: 10px; border-bottom: 1px solid #eee; padding-bottom: 10px;">
        Existing Rules
      </h3>
      <div :if={@routing_rules == []} style="padding: 20px; text-align: center; color: #888;">
        No routing rules yet. Create one above.
      </div>
      <table :if={@routing_rules != []}>
        <thead>
          <tr>
            <th>Name</th>
            <th>Tenant</th>
            <th>Source</th>
            <th>Targets</th>
            <th>Priority</th>
            <th>Conditions</th>
            <th>Status</th>
            <th style="text-align: right;">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={rule <- @routing_rules} id={"rule-#{rule.id}"}>
            <td style="font-weight: 500;">{rule.name}</td>
            <td>{if rule.tenant, do: rule.tenant.name, else: "-"}</td>
            <td>
              <span class="badge" style="background: #e3f2fd; color: #1565c0;">
                {if rule.source_channel, do: rule.source_channel.name, else: "-"}
              </span>
            </td>
            <td>
              <%= for tid <- rule.target_channel_ids do %>
                <span class="badge" style="background: #f3e5f5; color: #7b1fa2; margin-right: 4px;">
                  {channel_name(tid, @channels)}
                </span>
              <% end %>
            </td>
            <td>
              {rule.priority}<span :if={rule.stop_processing} title="stop processing" style="color: #888;"> (stop)</span>
            </td>
            <td style="max-width: 280px;">
              <code style="font-size: 0.8em; word-break: break-all;">{conditions_summary(rule.conditions)}</code>
              <div :if={rule.transformations != []} style="color: #888; font-size: 0.8em;">
                {length(rule.transformations)} transformation(s)
              </div>
            </td>
            <td>
              <span class={"badge badge-#{if rule.enabled, do: "active", else: "inactive"}"}>
                {if rule.enabled, do: "Enabled", else: "Disabled"}
              </span>
            </td>
            <td style="text-align: right; white-space: nowrap;">
              <button phx-click="edit" phx-value-id={rule.id} style="font-size: 0.85em;">
                Edit
              </button>
              <button
                phx-click="toggle_enabled"
                phx-value-id={rule.id}
                style="background: #6c757d; font-size: 0.85em; margin-left: 5px;"
              >
                {if rule.enabled, do: "Disable", else: "Enable"}
              </button>
              <button
                phx-click="delete"
                phx-value-id={rule.id}
                phx-confirm="Are you sure you want to delete this rule?"
                style="background: #dc3545; font-size: 0.85em; margin-left: 5px;"
              >
                Delete
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
