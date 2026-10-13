defmodule ConvergerWeb.Portal.RoutingRuleLive do
  use ConvergerWeb, :live_view

  alias Converger.Channels
  alias Converger.RoutingRules

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
    if socket.assigns.can_edit do
      rule = RoutingRules.get_routing_rule!(id)

      if rule.tenant_id == socket.assigns.current_tenant.id do
        toggle_rule_enabled(socket, rule)
      else
        {:noreply, put_flash(socket, :error, "Unauthorized")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}
    end
  end

  defp toggle_rule_enabled(socket, rule) do
    case RoutingRules.update_routing_rule(rule, %{enabled: !rule.enabled}, build_actor(socket)) do
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
        <div :if={@routing_rules != []} class="overflow-x-auto">
          <.table id="routing-rules" rows={@routing_rules} row_id={&"rule-#{&1.id}"}>
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
        <.empty_state :if={@routing_rules == []}>No routing rules found.</.empty_state>
      </.panel>
    </Layouts.app>
    """
  end
end
