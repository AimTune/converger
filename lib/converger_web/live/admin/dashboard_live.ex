defmodule ConvergerWeb.Admin.DashboardLive do
  use ConvergerWeb, :live_view

  alias Converger.Repo
  alias Converger.Tenants.Tenant
  alias Converger.Channels.Channel
  alias Converger.Channels.Health
  alias Converger.Conversations.Conversation
  alias Converger.Activities.Activity
  alias Converger.Deliveries

  import Ecto.Query

  def mount(_params, _session, socket) do
    if connected?(socket) do
      ConvergerWeb.Endpoint.subscribe("channel_health")
    end

    stats = %{
      tenants: Repo.aggregate(Tenant, :count, :id),
      channels: Repo.aggregate(Channel, :count, :id),
      conversations: Repo.aggregate(Conversation, :count, :id),
      activities: Repo.aggregate(Activity, :count, :id)
    }

    channel_modes =
      from(c in Channel, group_by: c.mode, select: {c.mode, count(c.id)})
      |> Repo.all()
      |> Map.new()

    delivery_stats = Deliveries.count_by_status()

    channels =
      from(c in Channel,
        where: c.status == "active" and c.type in ["webhook", "whatsapp_meta", "whatsapp_infobip"],
        preload: [:tenant]
      )
      |> Repo.all()

    channel_ids = Enum.map(channels, & &1.id)
    health_map = Health.get_latest_health_map(channel_ids)

    {:ok,
     assign(socket,
       stats: stats,
       channel_modes: channel_modes,
       delivery_stats: delivery_stats,
       channels: channels,
       health_map: health_map,
       page_title: "Dashboard"
     )}
  end

  def handle_info(%{event: "health_changed", payload: payload}, socket) do
    health_map =
      Map.put(socket.assigns.health_map, payload.channel_id, %{
        status: payload.status,
        failure_rate: payload.failure_rate,
        total_deliveries: payload.total_deliveries,
        failed_deliveries: payload.failed_deliveries,
        checked_at: payload.checked_at
      })

    {:noreply, assign(socket, health_map: health_map)}
  end

  defp health_color("healthy"), do: "#4CAF50"
  defp health_color("degraded"), do: "#FF9800"
  defp health_color("unhealthy"), do: "#f44336"
  defp health_color(_), do: "#9E9E9E"

  defp health_label("healthy"), do: "Healthy"
  defp health_label("degraded"), do: "Degraded"
  defp health_label("unhealthy"), do: "Unhealthy"
  defp health_label(_), do: "Unknown"

  def render(assigns) do
    ~H"""
    <h1>Dashboard</h1>
    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px;">
      <div class="card">
        <h3>Tenants</h3>
        <p style="font-size: 2em; font-weight: bold;"><%= @stats.tenants %></p>
      </div>
      <div class="card">
        <h3>Channels</h3>
        <p style="font-size: 2em; font-weight: bold;"><%= @stats.channels %></p>
        <div style="display: flex; gap: 8px; margin-top: 8px;">
          <span class="badge badge-inbound"><%= "← #{Map.get(@channel_modes, "inbound", 0)}" %></span>
          <span class="badge badge-outbound"><%= "→ #{Map.get(@channel_modes, "outbound", 0)}" %></span>
          <span class="badge badge-duplex"><%= "↔ #{Map.get(@channel_modes, "duplex", 0)}" %></span>
        </div>
      </div>
      <div class="card">
        <h3>Conversations</h3>
        <p style="font-size: 2em; font-weight: bold;"><%= @stats.conversations %></p>
      </div>
      <div class="card">
        <h3>Activities</h3>
        <p style="font-size: 2em; font-weight: bold;"><%= @stats.activities %></p>
      </div>
    </div>

    <h2 style="margin-top: 30px;">Deliveries</h2>
    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 20px;">
      <div class="card">
        <h3>Pending</h3>
        <p style="font-size: 2em; font-weight: bold;"><%= Map.get(@delivery_stats, "pending", 0) %></p>
      </div>
      <div class="card">
        <h3>Sent</h3>
        <p style="font-size: 2em; font-weight: bold; color: #2196F3;"><%= Map.get(@delivery_stats, "sent", 0) %></p>
      </div>
      <div class="card">
        <h3>Delivered</h3>
        <p style="font-size: 2em; font-weight: bold; color: #4CAF50;"><%= Map.get(@delivery_stats, "delivered", 0) %></p>
      </div>
      <div class="card">
        <h3>Read</h3>
        <p style="font-size: 2em; font-weight: bold; color: #8BC34A;"><%= Map.get(@delivery_stats, "read", 0) %></p>
      </div>
      <div class="card">
        <h3>Failed</h3>
        <p style="font-size: 2em; font-weight: bold; color: red;"><%= Map.get(@delivery_stats, "failed", 0) %></p>
      </div>
    </div>

    <h2 style="margin-top: 30px;">Channel Health</h2>
    <div :if={@channels == []} class="card">
      <p style="color: #999;">No active external channels.</p>
    </div>
    <div :if={@channels != []} class="card">
      <table>
        <thead>
          <tr>
            <th>Channel</th>
            <th>Type</th>
            <th>Tenant</th>
            <th>Health</th>
            <th>Failure Rate</th>
            <th>Deliveries (1h)</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={channel <- @channels}>
            <td style="font-weight: 500;"><%= channel.name %></td>
            <td><span class="badge"><%= channel.type %></span></td>
            <td><%= if channel.tenant, do: channel.tenant.name, else: "-" %></td>
            <% health = Map.get(@health_map, channel.id) %>
            <td>
              <span style={"display: inline-flex; align-items: center; gap: 6px; color: #{health_color(health_status(health))}"}>
                <span style={"width: 10px; height: 10px; border-radius: 50%; background: #{health_color(health_status(health))}; display: inline-block;"}></span>
                <%= health_label(health_status(health)) %>
              </span>
            </td>
            <td>
              <%= if health, do: "#{Float.round(health_rate(health) * 100, 1)}%", else: "-" %>
            </td>
            <td>
              <%= if health, do: health_total(health), else: "-" %>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp health_status(nil), do: "unknown"
  defp health_status(%{status: status}), do: status

  defp health_rate(%{failure_rate: rate}), do: rate
  defp health_rate(_), do: 0.0

  defp health_total(%{total_deliveries: total}), do: total
  defp health_total(_), do: 0
end
