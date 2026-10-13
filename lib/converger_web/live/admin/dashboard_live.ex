defmodule ConvergerWeb.Admin.DashboardLive do
  use ConvergerWeb, :live_view

  alias Converger.Activities.Activity
  alias Converger.Channels.Channel
  alias Converger.Channels.Health
  alias Converger.Conversations.Conversation
  alias Converger.Deliveries
  alias Converger.Repo
  alias Converger.Tenants.Tenant

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

    channels = Health.list_monitored_channels()
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

  defp health_dot_class("healthy"), do: "status-success"
  defp health_dot_class("degraded"), do: "status-warning"
  defp health_dot_class("unhealthy"), do: "status-error"
  defp health_dot_class(_), do: "status-neutral"

  defp health_text_class("healthy"), do: "text-success"
  defp health_text_class("degraded"), do: "text-warning"
  defp health_text_class("unhealthy"), do: "text-error"
  defp health_text_class(_), do: "text-base-content/60"

  defp health_label("healthy"), do: "Healthy"
  defp health_label("degraded"), do: "Degraded"
  defp health_label("unhealthy"), do: "Unhealthy"
  defp health_label(_), do: "Unknown"

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Dashboard
        <:subtitle>Platform-wide totals, delivery outcomes and channel health.</:subtitle>
      </.header>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.stat title="Tenants" value={@stats.tenants} />
        <.stat title="Channels" value={@stats.channels}>
          <.mode_badges channel_modes={@channel_modes} />
        </.stat>
        <.stat title="Conversations" value={@stats.conversations} />
        <.stat title="Activities" value={@stats.activities} />
      </div>

      <section class="space-y-3">
        <h2 class="text-base font-semibold">Deliveries</h2>
        <div class="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-5">
        <.stat title="Pending" value={Map.get(@delivery_stats, "pending", 0)} class="text-warning" />
        <.stat title="Sent" value={Map.get(@delivery_stats, "sent", 0)} class="text-info" />
        <.stat
          title="Delivered"
          value={Map.get(@delivery_stats, "delivered", 0)}
          class="text-success"
        />
        <.stat title="Read" value={Map.get(@delivery_stats, "read", 0)} class="text-success" />
        <.stat title="Failed" value={Map.get(@delivery_stats, "failed", 0)} class="text-error" />
        </div>
      </section>

      <.panel title="Channel Health">
        <.empty_state :if={@channels == []}>No active external channels.</.empty_state>
        <div :if={@channels != []} class="overflow-x-auto">
          <.table id="channel-health" rows={@channels} row_id={&"channel-health-#{&1.id}"}>
            <:col :let={channel} label="Channel">
              <span class="font-medium">{channel.name}</span>
            </:col>
            <:col :let={channel} label="Type">
              <span class="badge badge-sm badge-ghost">{channel.type}</span>
            </:col>
            <:col :let={channel} label="Tenant">
              {if channel.tenant, do: channel.tenant.name, else: "-"}
            </:col>
            <:col :let={channel} label="Health">
              <span class={[
                "inline-flex items-center gap-2",
                health_text_class(health_status(Map.get(@health_map, channel.id)))
              ]}>
                <span
                  aria-hidden="true"
                  class={[
                    "status",
                    health_dot_class(health_status(Map.get(@health_map, channel.id)))
                  ]}
                />
                {health_label(health_status(Map.get(@health_map, channel.id)))}
              </span>
            </:col>
            <:col :let={channel} label="Failure Rate">
              {if health = Map.get(@health_map, channel.id),
                do: "#{Float.round(health_rate(health) * 100, 1)}%",
                else: "-"}
            </:col>
            <:col :let={channel} label="Deliveries (1h)">
              {if health = Map.get(@health_map, channel.id), do: health_total(health), else: "-"}
            </:col>
          </.table>
        </div>
      </.panel>
    </Layouts.app>
    """
  end

  attr :channel_modes, :map, required: true

  defp mode_badges(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <.badge value="inbound" title="Inbound">← {Map.get(@channel_modes, "inbound", 0)}</.badge>
      <.badge value="outbound" title="Outbound">→ {Map.get(@channel_modes, "outbound", 0)}</.badge>
      <.badge value="duplex" title="Duplex">↔ {Map.get(@channel_modes, "duplex", 0)}</.badge>
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
