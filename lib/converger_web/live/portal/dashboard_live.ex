defmodule ConvergerWeb.Portal.DashboardLive do
  use ConvergerWeb, :live_view

  alias Converger.Repo
  alias Converger.Channels.Channel
  alias Converger.Conversations.Conversation
  alias Converger.Activities.Activity

  import Ecto.Query

  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.current_tenant.id

    stats = %{
      channels:
        from(c in Channel, where: c.tenant_id == ^tenant_id)
        |> Repo.aggregate(:count, :id),
      conversations:
        from(c in Conversation, where: c.tenant_id == ^tenant_id)
        |> Repo.aggregate(:count, :id),
      activities:
        from(a in Activity, where: a.tenant_id == ^tenant_id)
        |> Repo.aggregate(:count, :id)
    }

    channel_modes =
      from(c in Channel,
        where: c.tenant_id == ^tenant_id,
        group_by: c.mode,
        select: {c.mode, count(c.id)}
      )
      |> Repo.all()
      |> Map.new()

    {:ok,
     assign(socket,
       stats: stats,
       channel_modes: channel_modes,
       page_title: "Dashboard"
     )}
  end

  def render(assigns) do
    ~H"""
    <h1>Dashboard</h1>
    <p style="color: #666; margin-bottom: 20px;">
      Tenant: <strong><%= @current_tenant.name %></strong>
    </p>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px;">
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
    """
  end
end
