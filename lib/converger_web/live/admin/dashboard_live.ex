defmodule ConvergerWeb.Admin.DashboardLive do
  use ConvergerWeb, :live_view

  alias Converger.Repo
  alias Converger.Tenants.Tenant
  alias Converger.Channels.Channel
  alias Converger.Conversations.Conversation
  alias Converger.Activities.Activity
  alias Converger.Deliveries

  import Ecto.Query

  def mount(_params, _session, socket) do
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

    {:ok, assign(socket, stats: stats, channel_modes: channel_modes, delivery_stats: delivery_stats, page_title: "Dashboard")}
  end

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
          <span class="badge badge-inbound">← <%= Map.get(@channel_modes, "inbound", 0) %></span>
          <span class="badge badge-outbound">→ <%= Map.get(@channel_modes, "outbound", 0) %></span>
          <span class="badge badge-duplex">↔ <%= Map.get(@channel_modes, "duplex", 0) %></span>
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
    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px;">
      <div class="card">
        <h3>Pending</h3>
        <p style="font-size: 2em; font-weight: bold;"><%= Map.get(@delivery_stats, "pending", 0) %></p>
      </div>
      <div class="card">
        <h3>Delivered</h3>
        <p style="font-size: 2em; font-weight: bold; color: green;"><%= Map.get(@delivery_stats, "delivered", 0) %></p>
      </div>
      <div class="card">
        <h3>Failed</h3>
        <p style="font-size: 2em; font-weight: bold; color: red;"><%= Map.get(@delivery_stats, "failed", 0) %></p>
      </div>
    </div>
    """
  end
end
