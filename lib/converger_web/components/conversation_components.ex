defmodule ConvergerWeb.ConversationComponents do
  @moduledoc """
  Pieces shared by the admin (`/admin/conversations/:id`) and portal
  (`/portal/conversations/:id`) conversation detail pages: delivery status
  badges, the participant panel and the live-tail indicator, plus the
  delivery bookkeeping both pages do for their transcripts.
  """
  use Phoenix.Component

  import ConvergerWeb.CoreComponents, only: [badge: 1, button: 1, panel: 1]

  alias Converger.Deliveries
  alias Converger.Deliveries.Delivery

  @delivery_statuses ~w(pending sent delivered read failed)

  @doc """
  `%{activity_id => delivery}` with the most advanced delivery of each of
  `activities` (an activity routed to several channels has one delivery per
  channel; the badge shows the furthest one).
  """
  def delivery_map(activities) do
    activities
    |> Enum.map(& &1.id)
    |> Deliveries.list_deliveries_for_activities()
    |> Enum.group_by(& &1.activity_id)
    |> Map.new(fn {activity_id, deliveries} ->
      {activity_id, Enum.max_by(deliveries, &Delivery.status_rank(&1.status))}
    end)
  end

  @doc """
  Merge a `delivery_status` broadcast payload into `delivery_map`: it
  replaces the shown delivery when it is the same delivery (any new status,
  failures included) or a more advanced one.
  """
  def put_delivery_status(delivery_map, %{activity_id: activity_id, status: status} = payload) do
    incoming =
      payload
      |> Map.take([:status, :sent_at, :delivered_at, :read_at])
      |> Map.put(:id, Map.get(payload, :delivery_id))

    Map.update(delivery_map, activity_id, incoming, fn current ->
      if Map.get(current, :id) == incoming.id or
           Delivery.status_rank(status) >= Delivery.status_rank(current.status),
         do: incoming,
         else: current
    end)
  end

  @doc """
  The delivery status of an activity: a colored badge with the status as
  text (the check marks are decorative and hidden from screen readers).
  Renders nothing for activities without deliveries.
  """
  attr :delivery, :any, required: true
  attr :id, :string, default: nil

  def delivery_badge(%{delivery: %{status: status}} = assigns)
      when status in @delivery_statuses do
    ~H"""
    <span
      id={@id}
      class={["badge badge-sm gap-1 whitespace-nowrap", delivery_badge_class(@delivery.status)]}
      data-status={@delivery.status}
    >
      <span aria-hidden="true">{delivery_symbol(@delivery.status)}</span>
      <span class="sr-only">Delivery status:</span>
      {@delivery.status}
    </span>
    """
  end

  def delivery_badge(assigns), do: ~H""

  defp delivery_badge_class("pending"), do: "badge-ghost"
  defp delivery_badge_class("sent"), do: "badge-secondary"
  defp delivery_badge_class("delivered"), do: "badge-success"
  defp delivery_badge_class("read"), do: "badge-info"
  defp delivery_badge_class("failed"), do: "badge-error"

  defp delivery_symbol("pending"), do: "…"
  defp delivery_symbol("sent"), do: "✓"
  defp delivery_symbol("delivered"), do: "✓✓"
  defp delivery_symbol("read"), do: "✓✓"
  defp delivery_symbol("failed"), do: "✗"

  @doc "The participant column of a conversation list (external id and display name)."
  attr :participant, :any, required: true

  def participant_cell(assigns) do
    ~H"""
    <span :if={@participant} class="font-mono text-xs break-all">{@participant.external_id}</span>
    <span :if={@participant && @participant.display_name} class="block text-xs">
      {@participant.display_name}
    </span>
    <span :if={!@participant} class="text-base-content/60">-</span>
    """
  end

  @doc """
  Close / Reopen buttons (events `"close"` and `"reopen"`); the caller
  renders them only for users allowed to change the status.
  """
  attr :conversation, :any, required: true

  def status_actions(assigns) do
    ~H"""
    <div>
      <.button
        :if={@conversation.status == "active"}
        id="close-conversation"
        phx-click="close"
        data-confirm="Close this conversation? It will stop accepting activities."
        size="sm"
        variant="error"
      >
        Close conversation
      </.button>
      <.button
        :if={@conversation.status == "closed"}
        id="reopen-conversation"
        phx-click="reopen"
        size="sm"
        variant="neutral"
      >
        Reopen conversation
      </.button>
    </div>
    """
  end

  @doc "Pulsing dot announcing that the transcript updates in real time."
  attr :connected, :boolean, required: true

  def live_indicator(assigns) do
    ~H"""
    <span
      id="live-indicator"
      class="inline-flex items-center gap-1.5 text-xs font-medium text-base-content/70"
      role="status"
    >
      <span :if={@connected} class="relative flex size-2">
        <span class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-75">
        </span>
        <span class="relative inline-flex size-2 rounded-full bg-success"></span>
      </span>
      <span :if={!@connected} class="inline-flex size-2 rounded-full bg-base-300"></span>
      {if @connected, do: "Live", else: "Connecting…"}
    </span>
    """
  end

  @doc """
  The conversation's external party (the participant on its origin channel)
  and its activity window. Expects `conversation.participant` and
  `conversation.channel` preloaded.
  """
  attr :conversation, :any, required: true

  def participant_panel(assigns) do
    ~H"""
    <.panel id="participant-panel" title="Participant">
      <dl :if={@conversation.participant} class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <dt class="text-sm text-base-content/60">External ID</dt>
          <dd id="participant-external-id" class="font-mono text-sm break-all">
            {@conversation.participant.external_id}
          </dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">Display name</dt>
          <dd>{@conversation.participant.display_name || "-"}</dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">Channel</dt>
          <dd>{channel_label(@conversation.channel)}</dd>
        </div>
        <div :if={@conversation.participant.opted_out_at}>
          <dt class="text-sm text-base-content/60">Opted out</dt>
          <dd><.badge value="disabled">{format_time(@conversation.participant.opted_out_at)}</.badge></dd>
        </div>
        <div :if={@conversation.participant.metadata not in [nil, %{}]} class="sm:col-span-2">
          <dt class="text-sm text-base-content/60">Profile</dt>
          <dd>
            <code class="block font-mono text-xs break-all">
              {Jason.encode!(@conversation.participant.metadata)}
            </code>
          </dd>
        </div>
      </dl>
      <p :if={!@conversation.participant} class="text-sm text-base-content/60">
        No external participant (the conversation was started through the API or a WebSocket client).
      </p>
      <dl class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <dt class="text-sm text-base-content/60">First activity</dt>
          <dd class="text-sm">{format_time(@conversation.inserted_at)}</dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">Last activity</dt>
          <dd id="conversation-last-activity" class="text-sm">
            {format_time(@conversation.updated_at)}
          </dd>
        </div>
      </dl>
    </.panel>
    """
  end

  defp channel_label(%{name: name, type: type}), do: "#{name} (#{type})"
  defp channel_label(_), do: "-"

  @doc "A UTC timestamp as `YYYY-MM-DD HH:MM:SS UTC`."
  def format_time(nil), do: "-"
  def format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
  def format_time(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
  def format_time(other), do: to_string(other)
end
