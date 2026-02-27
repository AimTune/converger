defmodule ConvergerWeb.Admin.RoutingRuleLive do
  use ConvergerWeb, :live_view

  alias Converger.RoutingRules
  alias Converger.RoutingRules.RoutingRule
  alias Converger.Tenants
  alias Converger.Channels

  def mount(_params, _session, socket) do
    tenants = Tenants.list_tenants()
    channels = Channels.list_channels()
    actor = build_actor(socket)

    {:ok,
     assign(socket,
       routing_rules: RoutingRules.list_routing_rules(),
       tenants: tenants,
       channels: channels,
       filtered_channels: [],
       source_candidates: [],
       target_candidates: [],
       selected_tenant_id: nil,
       selected_source_channel_id: nil,
       form: to_form(RoutingRules.change_routing_rule(%RoutingRule{})),
       page_title: "Routing Rules",
       actor: actor
     )}
  end

  def handle_event("form_changed", %{"routing_rule" => params}, socket) do
    tenant_id = params["tenant_id"]
    source_channel_id = params["source_channel_id"]

    filtered =
      if tenant_id != "" do
        Enum.filter(socket.assigns.channels, &(&1.tenant_id == tenant_id))
      else
        []
      end

    source_candidates = Enum.filter(filtered, &(&1.mode in ["inbound", "duplex"]))
    target_candidates = Enum.filter(filtered, &(&1.mode in ["outbound", "duplex"]))

    source_id =
      if source_channel_id != "" and Enum.any?(source_candidates, &(&1.id == source_channel_id)) do
        source_channel_id
      else
        nil
      end

    {:noreply,
     assign(socket,
       filtered_channels: filtered,
       source_candidates: source_candidates,
       target_candidates: target_candidates,
       selected_tenant_id: tenant_id,
       selected_source_channel_id: source_id
     )}
  end

  def handle_event("save", %{"routing_rule" => params}, socket) do
    target_ids = Map.get(params, "target_channel_ids", [])
    target_ids = Enum.reject(target_ids, &(&1 == ""))
    params = Map.put(params, "target_channel_ids", target_ids)

    case RoutingRules.create_routing_rule(params, socket.assigns.actor) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Routing rule created")
         |> assign(
           routing_rules: RoutingRules.list_routing_rules(),
           form: to_form(RoutingRules.change_routing_rule(%RoutingRule{})),
           filtered_channels: [],
           source_candidates: [],
           target_candidates: [],
           selected_tenant_id: nil,
           selected_source_channel_id: nil
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
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

  defp build_actor(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> %{type: "admin", id: address |> :inet.ntoa() |> to_string()}
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

  def render(assigns) do
    ~H"""
    <h1 style="margin-bottom: 5px;">Routing Rules</h1>
    <p style="color: #666; margin-top: 0; margin-bottom: 20px;">
      Route incoming messages from a source channel to one or more target channels.
    </p>

    <div class="card">
      <h3 style="margin-top: 0; margin-bottom: 15px; border-bottom: 1px solid #eee; padding-bottom: 10px;">
        Create Routing Rule
      </h3>
      <.form for={@form} phx-submit="save" phx-change="form_changed">
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px;">
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              Tenant
            </label>
            <select name="routing_rule[tenant_id]" required style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; background: #fff;">
              <option value="">Select Tenant</option>
              <%= for tenant <- @tenants do %>
                <option value={tenant.id} selected={@selected_tenant_id == tenant.id}>
                  <%= tenant.name %>
                </option>
              <% end %>
            </select>
          </div>

          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              Rule Name
            </label>
            <.input field={@form[:name]} placeholder="e.g. WhatsApp to WebSocket" style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px;" />
          </div>

          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              Source Channel
            </label>
            <select name="routing_rule[source_channel_id]" required style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; background: #fff;">
              <option value="">
                <%= if @selected_tenant_id, do: "Select Source Channel", else: "Select a tenant first" %>
              </option>
              <%= for ch <- @source_candidates do %>
                <option value={ch.id} selected={@selected_source_channel_id == ch.id}>
                  <%= ch.name %> (<%= ch.type %>) <%= mode_indicator(ch.mode) %>
                </option>
              <% end %>
            </select>
          </div>
        </div>

        <div :if={@selected_source_channel_id && length(target_channels(@target_candidates, @selected_source_channel_id)) > 0} style="margin-top: 20px; padding: 15px; background: #f8f9fa; border-radius: 6px; border: 1px solid #e9ecef;">
          <label style="display: block; font-weight: 600; margin-bottom: 10px; font-size: 0.9em; color: #555;">
            Target Channels (outbound/duplex only)
          </label>
          <div style="display: flex; gap: 12px; flex-wrap: wrap;">
            <%= for ch <- target_channels(@target_candidates, @selected_source_channel_id) do %>
              <label style="display: flex; align-items: center; gap: 6px; padding: 6px 12px; background: #fff; border: 1px solid #ddd; border-radius: 4px; cursor: pointer; font-size: 0.9em;">
                <input type="checkbox" name="routing_rule[target_channel_ids][]" value={ch.id} />
                <%= ch.name %>
                <span style="color: #888; font-size: 0.85em;">(<%= ch.type %>) <%= mode_indicator(ch.mode) %></span>
              </label>
            <% end %>
          </div>
        </div>

        <div :if={@selected_source_channel_id && length(target_channels(@target_candidates, @selected_source_channel_id)) == 0} style="margin-top: 20px; padding: 15px; background: #fff3cd; border-radius: 6px; border: 1px solid #ffc107; color: #856404; font-size: 0.9em;">
          No outbound-capable channels available for this tenant. Create more channels first.
        </div>

        <button type="submit" style="margin-top: 15px; padding: 8px 20px; font-size: 0.95em;">
          Create Rule
        </button>
      </.form>
    </div>

    <div class="card">
      <h3 style="margin-top: 0; margin-bottom: 10px; border-bottom: 1px solid #eee; padding-bottom: 10px;">
        Existing Rules
      </h3>
      <div :if={length(@routing_rules) == 0} style="padding: 20px; text-align: center; color: #888;">
        No routing rules yet. Create one above.
      </div>
      <table :if={length(@routing_rules) > 0}>
        <thead>
          <tr>
            <th>Name</th>
            <th>Tenant</th>
            <th>Source</th>
            <th>Targets</th>
            <th>Status</th>
            <th style="text-align: right;">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={rule <- @routing_rules}>
            <td style="font-weight: 500;"><%= rule.name %></td>
            <td><%= if rule.tenant, do: rule.tenant.name, else: "-" %></td>
            <td>
              <span class="badge" style="background: #e3f2fd; color: #1565c0;">
                <%= if rule.source_channel, do: rule.source_channel.name, else: "-" %>
              </span>
            </td>
            <td>
              <%= for tid <- rule.target_channel_ids do %>
                <span class="badge" style="background: #f3e5f5; color: #7b1fa2; margin-right: 4px;">
                  <%= channel_name(tid, @channels) %>
                </span>
              <% end %>
            </td>
            <td>
              <span class={"badge badge-#{if rule.enabled, do: "active", else: "inactive"}"}>
                <%= if rule.enabled, do: "Enabled", else: "Disabled" %>
              </span>
            </td>
            <td style="text-align: right; white-space: nowrap;">
              <button phx-click="toggle_enabled" phx-value-id={rule.id} style="background: #6c757d; font-size: 0.85em;">
                <%= if rule.enabled, do: "Disable", else: "Enable" %>
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
