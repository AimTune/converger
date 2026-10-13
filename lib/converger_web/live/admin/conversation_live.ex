defmodule ConvergerWeb.Admin.ConversationLive do
  use ConvergerWeb, :live_view

  alias Converger.Repo

  alias Converger.Activities
  alias Converger.Channels
  alias Converger.Deliveries
  alias Converger.Tenants

  @filter_keys ~w(tenant_id channel_id status q sort per_page)
  @per_page_options [25, 50, 100]

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       tenants: Tenants.list_tenants(),
       channels: Channels.list_channels(),
       filters: default_filters(),
       per_page_options: @per_page_options,
       page_title: "Conversations"
     )}
  end

  defp default_filters do
    %{
      "tenant_id" => "",
      "channel_id" => "",
      "status" => "",
      "q" => "",
      "sort" => "desc",
      "per_page" => to_string(Converger.Pagination.default_limit(:default))
    }
  end

  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    filters = Map.merge(default_filters(), Map.take(params, @filter_keys))

    socket
    |> assign(filters: filters, next_cursor: nil, loaded_count: 0)
    |> load_conversations(reset: true)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    conversation =
      Converger.Conversations.get_conversation!(id)
      |> Repo.preload([:tenant, :channel])

    # Subscribe to real-time status updates
    if connected?(socket) do
      ConvergerWeb.Endpoint.subscribe("conversation:#{id}")
    end

    # Open on the most recent page; older activities load on demand.
    {activities, has_older} = Activities.page_recent_activities(id)

    socket
    |> assign(
      conversation: conversation,
      delivery_map: %{},
      has_older: has_older,
      oldest_seq: activities |> List.first() |> seq_or(nil),
      newest_seq: activities |> List.last() |> seq_or(nil),
      activity_count: length(activities)
    )
    |> assign_deliveries(activities)
    |> stream(:activities, activities, reset: true)
  end

  defp seq_or(nil, default), do: default
  defp seq_or(%{seq: seq}, _default), do: seq

  # Keyset page of conversations; `reset: true` starts over (filter change).
  defp load_conversations(socket, opts) do
    reset = Keyword.get(opts, :reset, false)
    filters = socket.assigns.filters
    cursor = if reset, do: nil, else: socket.assigns.next_cursor

    page =
      case Converger.Conversations.paginate_conversations(
             Map.take(filters, ~w(tenant_id channel_id status q)),
             cursor: cursor,
             limit: per_page(filters),
             direction: sort_direction(filters),
             preload: [:tenant, :channel]
           ) do
        {:ok, page} -> page
        {:error, :invalid_cursor} -> %Converger.Pagination.Page{}
      end

    loaded = if reset, do: 0, else: socket.assigns.loaded_count

    socket
    |> stream(:conversations, page.entries, reset: reset)
    |> assign(
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      loaded_count: loaded + length(page.entries)
    )
  end

  defp per_page(filters) do
    case Integer.parse(filters["per_page"] || "") do
      {n, ""} when n in @per_page_options -> n
      _ -> Converger.Pagination.default_limit(:default)
    end
  end

  defp sort_direction(%{"sort" => "asc"}), do: :asc
  defp sort_direction(_), do: :desc

  defp assign_deliveries(socket, activities) do
    activity_ids = Enum.map(activities, & &1.id)
    deliveries = Deliveries.list_deliveries_for_activities(activity_ids)

    delivery_map =
      Enum.group_by(deliveries, & &1.activity_id)
      |> Map.new(fn {activity_id, dels} ->
        # Pick the most advanced delivery status for display
        best =
          Enum.max_by(dels, &Converger.Deliveries.Delivery.status_rank(&1.status), fn ->
            hd(dels)
          end)

        {activity_id, best}
      end)

    assign(socket, delivery_map: Map.merge(socket.assigns.delivery_map, delivery_map))
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    params = Map.take(filters, @filter_keys)
    {:noreply, push_patch(socket, to: ~p"/admin/conversations?#{params}")}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply, load_conversations(socket, reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("load_older", _params, socket) do
    %{conversation: conversation, oldest_seq: oldest_seq} = socket.assigns

    if socket.assigns.has_older and is_integer(oldest_seq) do
      {activities, has_older} =
        Activities.page_recent_activities(conversation.id, before_seq: oldest_seq)

      socket =
        socket
        |> assign_deliveries(activities)
        |> assign(
          has_older: has_older,
          oldest_seq: activities |> List.first() |> seq_or(oldest_seq),
          activity_count: socket.assigns.activity_count + length(activities)
        )

      # Prepend: inserting newest-first at index 0 keeps ascending order.
      socket =
        activities
        |> Enum.reverse()
        |> Enum.reduce(socket, &stream_insert(&2, :activities, &1, at: 0))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %{topic: "conversation:" <> _, event: "delivery_status", payload: payload},
        socket
      ) do
    delivery_map =
      Map.put(socket.assigns.delivery_map, payload.activity_id, %{
        status: payload.status,
        sent_at: payload.sent_at,
        delivered_at: payload.delivered_at,
        read_at: payload.read_at
      })

    socket = assign(socket, delivery_map: delivery_map)

    # Stream rows only re-render when re-inserted; refresh the row if it is
    # within the loaded window.
    {:noreply, refresh_activity_row(socket, payload.activity_id)}
  end

  def handle_info(%{topic: "conversation:" <> _}, socket), do: {:noreply, socket}

  defp refresh_activity_row(%{assigns: %{live_action: :show}} = socket, activity_id) do
    %{conversation: conversation, oldest_seq: oldest, newest_seq: newest} = socket.assigns

    with true <- is_integer(oldest) and is_integer(newest),
         %Activities.Activity{} = activity <- Converger.Repo.get(Activities.Activity, activity_id),
         true <- activity.conversation_id == conversation.id,
         true <- activity.seq >= oldest and activity.seq <= newest do
      stream_insert(socket, :activities, activity)
    else
      _ -> socket
    end
  end

  defp refresh_activity_row(socket, _activity_id), do: socket

  def render(assigns) do
    case assigns.live_action do
      :index -> render_index(assigns)
      :show -> render_show(assigns)
    end
  end

  defp mode_arrow("inbound"), do: "←"
  defp mode_arrow("outbound"), do: "→"
  defp mode_arrow("duplex"), do: "↔"

  defp render_index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Conversations
        <:subtitle>Conversations across all tenants and channels.</:subtitle>
      </.header>

      <.panel title="Filters">
        <form phx-change="filter" id="filter-form">
          <div class="grid items-end gap-x-4 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-7">
            <.input
              type="select"
              id="filters_tenant_id"
              name="filters[tenant_id]"
              value={@filters["tenant_id"]}
              label="Tenant"
              prompt="All Tenants"
              options={Enum.map(@tenants, &{&1.name, &1.id})}
            />
            <.input
              type="select"
              id="filters_channel_id"
              name="filters[channel_id]"
              value={@filters["channel_id"]}
              label="Channel"
              prompt="All Channels"
              options={Enum.map(@channels, &{channel_option_label(&1), &1.id})}
            />
            <.input
              type="select"
              id="filters_status"
              name="filters[status]"
              value={@filters["status"]}
              label="Status"
              prompt="All Statuses"
              options={[{"Active", "active"}, {"Closed", "closed"}]}
            />
            <.input
              type="text"
              id="filters_q"
              name="filters[q]"
              value={@filters["q"]}
              label="Conversation ID"
              placeholder="Exact UUID"
              phx-debounce="400"
            />
            <.input
              type="select"
              id="filters_sort"
              name="filters[sort]"
              value={@filters["sort"]}
              label="Sort"
              options={[{"Newest first", "desc"}, {"Oldest first", "asc"}]}
            />
            <.input
              type="select"
              id="filters_per_page"
              name="filters[per_page]"
              value={@filters["per_page"]}
              label="Page size"
              options={Enum.map(@per_page_options, &{to_string(&1), to_string(&1)})}
            />
            <div class="mb-2">
              <.button href={~p"/admin/conversations"} variant="ghost">
                <.icon name="hero-x-mark" /> Reset
              </.button>
            </div>
          </div>
        </form>
      </.panel>

      <.panel>
        <div class="overflow-x-auto">
          <.table id="conversations" rows={@streams.conversations}>
            <:col :let={{_id, c}} label="ID">
              <span class="font-mono text-xs break-all">{c.id}</span>
            </:col>
            <:col :let={{_id, c}} label="Tenant">{c.tenant.name}</:col>
            <:col :let={{_id, c}} label="Channel">
              <span class="inline-flex items-center gap-1">
                {c.channel.name}
                <.badge value={c.channel.mode} title={c.channel.mode}>
                  {mode_arrow(c.channel.mode)}
                </.badge>
              </span>
            </:col>
            <:col :let={{_id, c}} label="Status"><.badge value={c.status} /></:col>
            <:col :let={{_id, c}} label="Created">
              <span class="text-xs whitespace-nowrap">{c.inserted_at}</span>
            </:col>
            <:action :let={{_id, c}}>
              <.button patch={~p"/admin/conversations/#{c.id}"} size="xs" variant="neutral">
                View Events
              </.button>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@loaded_count == 0}>No conversations found</.empty_state>
        <div class="flex flex-wrap items-center justify-between gap-2">
          <span class="text-sm text-base-content/60">Showing {@loaded_count} conversations</span>
          <.button
            :if={@has_more}
            id="load-more-conversations"
            phx-click="load_more"
            size="sm"
            variant="neutral"
          >
            Load more
          </.button>
        </div>
      </.panel>
    </Layouts.app>
    """
  end

  defp channel_option_label(c) do
    "#{c.name} (#{c.type} #{mode_arrow(c.mode)}) - #{c.tenant.name}"
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Conversation Details
        <:subtitle><span class="font-mono text-xs break-all">{@conversation.id}</span></:subtitle>
        <:actions>
          <.button patch={~p"/admin/conversations"} size="sm" variant="ghost">
            <.icon name="hero-arrow-left" /> Back to List
          </.button>
        </:actions>
      </.header>

      <.panel>
        <dl class="grid gap-4 sm:grid-cols-2">
          <div>
            <dt class="text-sm text-base-content/60">ID</dt>
            <dd><code class="font-mono text-xs break-all">{@conversation.id}</code></dd>
          </div>
          <div>
            <dt class="text-sm text-base-content/60">Channel</dt>
            <dd class="flex flex-wrap items-center gap-1">
              {@conversation.channel.name} ({@conversation.channel.type})
              <.badge value={@conversation.channel.mode} title={@conversation.channel.mode}>
                {mode_arrow(@conversation.channel.mode)}
              </.badge>
            </dd>
          </div>
          <div>
            <dt class="text-sm text-base-content/60">Tenant</dt>
            <dd>{@conversation.tenant.name}</dd>
          </div>
          <div>
            <dt class="text-sm text-base-content/60">Status</dt>
            <dd><.badge value={@conversation.status} /></dd>
          </div>
        </dl>
      </.panel>

      <.panel title="Events (Activities)">
        <div :if={@has_older} class="text-center">
          <.button id="load-older-activities" phx-click="load_older" size="sm" variant="neutral">
            <.icon name="hero-arrow-up" /> Load earlier activities
          </.button>
        </div>
        <div class="overflow-x-auto">
          <table class="table table-sm table-zebra">
            <thead>
              <tr>
                <th>Time</th>
                <th>Sender</th>
                <th>Message</th>
                <th>Delivery</th>
              </tr>
            </thead>
            <tbody id="activities" phx-update="stream">
              <tr :for={{dom_id, a} <- @streams.activities} id={dom_id}>
                <td class="text-xs whitespace-nowrap">{a.inserted_at}</td>
                <td class="font-semibold">{a.sender}</td>
                <td class="break-words">{a.text}</td>
                <td><.delivery_badge delivery={Map.get(@delivery_map, a.id)} /></td>
              </tr>
            </tbody>
          </table>
        </div>
        <.empty_state :if={@activity_count == 0}>No activities found</.empty_state>
      </.panel>
    </Layouts.app>
    """
  end

  attr :delivery, :any, required: true

  defp delivery_badge(%{delivery: %{status: status}} = assigns)
       when status in ~w(pending sent delivered read failed) do
    ~H"""
    <span
      class={["badge badge-sm", delivery_badge_class(@delivery.status)]}
      title={String.capitalize(@delivery.status)}
    >
      {delivery_symbol(@delivery.status)}
    </span>
    """
  end

  defp delivery_badge(assigns), do: ~H""

  defp delivery_badge_class("pending"), do: "badge-ghost"
  defp delivery_badge_class("sent"), do: "badge-secondary"
  defp delivery_badge_class("delivered"), do: "badge-success"
  defp delivery_badge_class("read"), do: "badge-info"
  defp delivery_badge_class("failed"), do: "badge-error"

  defp delivery_symbol("pending"), do: "..."
  defp delivery_symbol("sent"), do: "✓"
  defp delivery_symbol("delivered"), do: "✓✓"
  defp delivery_symbol("read"), do: "✓✓"
  defp delivery_symbol("failed"), do: "✗"
end
