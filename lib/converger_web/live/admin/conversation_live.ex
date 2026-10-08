defmodule ConvergerWeb.Admin.ConversationLive do
  use ConvergerWeb, :live_view

  alias Converger.Repo

  alias Converger.Tenants
  alias Converger.Channels
  alias Converger.Activities
  alias Converger.Deliveries

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
    <h1>Conversations</h1>

    <div class="card" style="margin-bottom: 20px;">
      <form phx-change="filter" id="filter-form">
        <div style="display: flex; gap: 15px; align-items: flex-end;">
          <div class="input-group" style="margin-bottom: 0;">
            <label>Tenant</label>
            <select name="filters[tenant_id]">
              <option value="">All Tenants</option>
              <option :for={t <- @tenants} value={t.id} selected={@filters["tenant_id"] == t.id}>
                <%= t.name %>
              </option>
            </select>
          </div>

          <div class="input-group" style="margin-bottom: 0;">
            <label>Channel</label>
            <select name="filters[channel_id]">
              <option value="">All Channels</option>
              <option :for={c <- @channels} value={c.id} selected={@filters["channel_id"] == c.id}>
                <%= c.name %> (<%= c.type %> <%= mode_arrow(c.mode) %>) - <%= c.tenant.name %>
              </option>
            </select>
          </div>

          <div class="input-group" style="margin-bottom: 0;">
            <label>Status</label>
            <select name="filters[status]">
              <option value="">All Statuses</option>
              <option value="active" selected={@filters["status"] == "active"}>Active</option>
              <option value="closed" selected={@filters["status"] == "closed"}>Closed</option>
            </select>
          </div>

          <div style="margin-bottom: 0;">
            <.input
              type="text"
              id="filters_q"
              name="filters[q]"
              value={@filters["q"]}
              label="Conversation ID"
              placeholder="Exact UUID"
              phx-debounce="400"
            />
          </div>

          <div style="margin-bottom: 0;">
            <.input
              type="select"
              id="filters_sort"
              name="filters[sort]"
              value={@filters["sort"]}
              label="Sort"
              options={[{"Newest first", "desc"}, {"Oldest first", "asc"}]}
            />
          </div>

          <div style="margin-bottom: 0;">
            <.input
              type="select"
              id="filters_per_page"
              name="filters[per_page]"
              value={@filters["per_page"]}
              label="Page size"
              options={Enum.map(@per_page_options, &{to_string(&1), to_string(&1)})}
            />
          </div>

          <a href={~p"/admin/conversations"} class="button button-outline" style="margin-bottom: 2px;">Reset</a>
        </div>
      </form>
    </div>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Tenant</th>
            <th>Channel</th>
            <th>Status</th>
            <th>Created</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody id="conversations" phx-update="stream">
          <tr :for={{dom_id, c} <- @streams.conversations} id={dom_id}>
            <td><small><%= c.id %></small></td>
            <td><%= c.tenant.name %></td>
            <td>
              <%= c.channel.name %>
              <span class={"badge badge-#{c.channel.mode}"} style="margin-left: 4px; font-size: 0.75em;">
                <%= mode_arrow(c.channel.mode) %>
              </span>
            </td>
            <td>
              <span class={"badge badge-#{c.status}"}>
                <%= c.status %>
              </span>
            </td>
            <td><%= c.inserted_at %></td>
            <td>
              <.link patch={~p"/admin/conversations/#{c.id}"} class="button button-clear">View Events</.link>
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@loaded_count == 0} style="text-align: center; color: #999;">No conversations found</p>
      <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 10px;">
        <small style="color: #666;">Showing <%= @loaded_count %> conversations</small>
        <button :if={@has_more} id="load-more-conversations" phx-click="load_more" class="button button-outline">
          Load more
        </button>
      </div>
    </div>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <div style="margin-bottom: 20px;">
      <.link patch={~p"/admin/conversations"} class="button button-outline">&larr; Back to List</.link>
    </div>

    <h1>Conversation Details</h1>

    <div class="card" style="margin-bottom: 20px;">
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div>
          <label>ID</label>
          <p><code><%= @conversation.id %></code></p>
          <label>Tenant</label>
          <p><%= @conversation.tenant.name %></p>
        </div>
        <div>
          <label>Channel</label>
          <p>
            <%= @conversation.channel.name %> (<%= @conversation.channel.type %>)
            <span class={"badge badge-#{@conversation.channel.mode}"}><%= mode_arrow(@conversation.channel.mode) %></span>
          </p>
          <label>Status</label>
          <p>
            <span class={"badge badge-#{@conversation.status}"}>
              <%= @conversation.status %>
            </span>
          </p>
        </div>
      </div>
    </div>

    <h2>Events (Activities)</h2>
    <div class="card">
      <div :if={@has_older} style="text-align: center; margin-bottom: 10px;">
        <button id="load-older-activities" phx-click="load_older" class="button button-outline">
          &uarr; Load earlier activities
        </button>
      </div>
      <table>
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
            <td style="white-space: nowrap;"><small><%= a.inserted_at %></small></td>
            <td><strong><%= a.sender %></strong></td>
            <td><%= a.text %></td>
            <td><%= delivery_badge(Map.get(@delivery_map, a.id)) %></td>
          </tr>
        </tbody>
      </table>
      <p :if={@activity_count == 0} style="text-align: center; color: #999;">No activities found</p>
    </div>
    """
  end

  defp delivery_badge(nil), do: ""

  defp delivery_badge(%{status: "pending"}) do
    assigns = %{}
    ~H|<span class="badge" title="Pending">...</span>|
  end

  defp delivery_badge(%{status: "sent"}) do
    assigns = %{}
    ~H|<span class="badge badge-outbound" title="Sent">&#10003;</span>|
  end

  defp delivery_badge(%{status: "delivered"}) do
    assigns = %{}
    ~H|<span class="badge badge-active" title="Delivered">&#10003;&#10003;</span>|
  end

  defp delivery_badge(%{status: "read"}) do
    assigns = %{}

    ~H|<span class="badge badge-active" title="Read" style="color: #2196F3;">&#10003;&#10003;</span>|
  end

  defp delivery_badge(%{status: "failed"}) do
    assigns = %{}
    ~H|<span class="badge badge-inactive" title="Failed">&#10007;</span>|
  end

  defp delivery_badge(_), do: ""
end
