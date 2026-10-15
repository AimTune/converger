defmodule ConvergerWeb.Portal.DashboardLive do
  use ConvergerWeb, :live_view

  alias Converger.Activities.Activity
  alias Converger.Channels.Channel
  alias Converger.Conversations.Conversation
  alias Converger.Repo

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

  defp tile_class,
    do:
      "block rounded-box transition hover:shadow-md focus-visible:outline-2 focus-visible:outline-primary"

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Dashboard
        <:subtitle>Tenant: <strong>{@current_tenant.name}</strong></:subtitle>
      </.header>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <.link id="tile-channels" navigate={~p"/portal/channels"} class={tile_class()}>
          <.stat title="Channels" value={@stats.channels}>
            <div class="flex flex-wrap gap-2">
              <.badge value="inbound" title="Inbound">
                ← {Map.get(@channel_modes, "inbound", 0)}
              </.badge>
              <.badge value="outbound" title="Outbound">
                → {Map.get(@channel_modes, "outbound", 0)}
              </.badge>
              <.badge value="duplex" title="Duplex">↔ {Map.get(@channel_modes, "duplex", 0)}</.badge>
            </div>
          </.stat>
        </.link>
        <.link id="tile-conversations" navigate={~p"/portal/conversations"} class={tile_class()}>
          <.stat title="Conversations" value={@stats.conversations} />
        </.link>
        <.stat title="Activities" value={@stats.activities} />
      </div>
      <div class="flex flex-wrap gap-2">
        <.button
          id="dashboard-failed-deliveries"
          navigate={~p"/portal/deliveries?#{[status: "failed"]}"}
          size="sm"
          variant="neutral"
        >
          <.icon name="hero-exclamation-triangle" class="size-4" /> Failed deliveries
        </.button>
      </div>
    </Layouts.app>
    """
  end
end
