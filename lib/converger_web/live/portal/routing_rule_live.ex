defmodule ConvergerWeb.Portal.RoutingRuleLive do
  use ConvergerWeb, :live_view

  alias Converger.RoutingRules
  alias Converger.Channels

  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.current_tenant.id
    can_edit = socket.assigns.tenant_role in ~w(owner admin member)

    {:ok,
     assign(socket,
       routing_rules: RoutingRules.list_routing_rules_for_tenant(tenant_id),
       channels: Channels.list_channels_for_tenant(tenant_id),
       page_title: "Routing Rules",
       can_edit: can_edit
     )}
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}
    else
      rule = RoutingRules.get_routing_rule!(id)

      if rule.tenant_id != socket.assigns.current_tenant.id do
        {:noreply, put_flash(socket, :error, "Unauthorized")}
      else
        case RoutingRules.update_routing_rule(
               rule,
               %{enabled: !rule.enabled},
               build_actor(socket)
             ) do
          {:ok, _} ->
            {:noreply,
             assign(socket,
               routing_rules:
                 RoutingRules.list_routing_rules_for_tenant(socket.assigns.current_tenant.id)
             )
             |> put_flash(:info, "Rule updated")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update rule")}
        end
      end
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
    <h1>Routing Rules</h1>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Source Channel</th>
            <th>Target Channels</th>
            <th>Enabled</th>
            <th :if={@can_edit}>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={rule <- @routing_rules}>
            <td style="font-weight: 500;"><%= rule.name %></td>
            <td><%= if rule.source_channel, do: rule.source_channel.name, else: "—" %></td>
            <td>
              <span :for={target_id <- rule.target_channel_ids} class="badge" style="margin-right: 4px;">
                <%= channel_name(@channels, target_id) %>
              </span>
            </td>
            <td>
              <span class={"badge badge-#{if rule.enabled, do: "active", else: "inactive"}"}>
                <%= if rule.enabled, do: "enabled", else: "disabled" %>
              </span>
            </td>
            <td :if={@can_edit}>
              <button phx-click="toggle_enabled" phx-value-id={rule.id} class="badge">
                <%= if rule.enabled, do: "Disable", else: "Enable" %>
              </button>
            </td>
          </tr>
          <tr :if={@routing_rules == []}>
            <td colspan="5" style="text-align: center; color: #999;">No routing rules found.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
