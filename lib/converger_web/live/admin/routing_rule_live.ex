defmodule ConvergerWeb.Admin.RoutingRuleLive do
  use ConvergerWeb, :live_view

  alias Converger.RoutingRules
  alias Converger.RoutingRules.RoutingRule
  alias Converger.Tenants
  alias Converger.Channels

  def mount(_params, _session, socket) do
    tenants = Tenants.list_tenants()
    channels = Channels.list_channels()

    {:ok,
     assign(socket,
       routing_rules: RoutingRules.list_routing_rules(),
       tenants: tenants,
       channels: channels,
       filtered_channels: [],
       selected_tenant_id: nil,
       form: to_form(RoutingRules.change_routing_rule(%RoutingRule{})),
       page_title: "Routing Rules"
     )}
  end

  def handle_event("tenant_changed", %{"routing_rule" => %{"tenant_id" => tenant_id}}, socket) do
    filtered =
      if tenant_id != "" do
        Enum.filter(socket.assigns.channels, &(&1.tenant_id == tenant_id))
      else
        []
      end

    {:noreply, assign(socket, filtered_channels: filtered, selected_tenant_id: tenant_id)}
  end

  def handle_event("save", %{"routing_rule" => params}, socket) do
    target_ids = Map.get(params, "target_channel_ids", [])
    # Filter out empty strings from checkbox form
    target_ids = Enum.reject(target_ids, &(&1 == ""))
    params = Map.put(params, "target_channel_ids", target_ids)

    case RoutingRules.create_routing_rule(params) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Routing rule created")
         |> assign(
           routing_rules: RoutingRules.list_routing_rules(),
           form: to_form(RoutingRules.change_routing_rule(%RoutingRule{})),
           filtered_channels: [],
           selected_tenant_id: nil
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    rule = RoutingRules.get_routing_rule!(id)

    case RoutingRules.toggle_routing_rule(rule) do
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

    case RoutingRules.delete_routing_rule(rule) do
      {:ok, _} ->
        {:noreply,
         assign(socket, routing_rules: RoutingRules.list_routing_rules())
         |> put_flash(:info, "Rule deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete rule")}
    end
  end

  defp channel_name(channel_id, channels) do
    case Enum.find(channels, &(&1.id == channel_id)) do
      nil -> String.slice(channel_id, 0..7) <> "..."
      ch -> ch.name
    end
  end

  def render(assigns) do
    ~H"""
    <h1>Routing Rules</h1>

    <div class="card">
      <h3>Create Routing Rule</h3>
      <.form for={@form} phx-submit="save" phx-change="tenant_changed">
        <div style="display: flex; gap: 10px; align-items: flex-start; flex-wrap: wrap;">
          <div>
            <label>Tenant</label>
            <select name="routing_rule[tenant_id]" required style="padding: 5px;">
              <option value="">Select Tenant</option>
              <%= for tenant <- @tenants do %>
                <option value={tenant.id} selected={@selected_tenant_id == tenant.id}>
                  <%= tenant.name %>
                </option>
              <% end %>
            </select>
          </div>

          <div>
            <label>Name</label>
            <.input field={@form[:name]} placeholder="Rule Name" />
          </div>

          <div>
            <label>Source Channel</label>
            <select name="routing_rule[source_channel_id]" required style="padding: 5px;">
              <option value="">Select Source</option>
              <%= for ch <- @filtered_channels do %>
                <option value={ch.id}><%= ch.name %> (<%= ch.type %>)</option>
              <% end %>
            </select>
          </div>
        </div>

        <div :if={length(@filtered_channels) > 0} style="margin-top: 10px;">
          <label>Target Channels</label>
          <div style="display: flex; gap: 10px; flex-wrap: wrap;">
            <%= for ch <- @filtered_channels do %>
              <label style="display: flex; align-items: center; gap: 4px;">
                <input type="checkbox" name="routing_rule[target_channel_ids][]" value={ch.id} />
                <%= ch.name %> (<%= ch.type %>)
              </label>
            <% end %>
          </div>
        </div>

        <button type="submit" style="margin-top: 10px;">Create Rule</button>
      </.form>
    </div>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Tenant</th>
            <th>Source</th>
            <th>Targets</th>
            <th>Enabled</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={rule <- @routing_rules}>
            <td><%= rule.name %></td>
            <td><%= if rule.tenant, do: rule.tenant.name, else: "-" %></td>
            <td>
              <span class="badge">
                <%= if rule.source_channel, do: rule.source_channel.name, else: "-" %>
              </span>
            </td>
            <td>
              <%= for tid <- rule.target_channel_ids do %>
                <span class="badge"><%= channel_name(tid, @channels) %></span>
              <% end %>
            </td>
            <td>
              <span class={"badge badge-#{if rule.enabled, do: "active", else: "inactive"}"}>
                <%= if rule.enabled, do: "enabled", else: "disabled" %>
              </span>
            </td>
            <td>
              <button phx-click="toggle_enabled" phx-value-id={rule.id} class="badge">
                <%= if rule.enabled, do: "Disable", else: "Enable" %>
              </button>
              <button
                phx-click="delete"
                phx-value-id={rule.id}
                phx-confirm="Are you sure?"
                class="badge badge-inactive"
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
