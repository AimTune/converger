defmodule ConvergerWeb.Admin.ConversationLive do
  use ConvergerWeb, :live_view

  alias Converger.Repo

  alias Converger.Tenants
  alias Converger.Channels
  alias Converger.Activities
  alias Converger.Deliveries

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       tenants: Tenants.list_tenants(),
       channels: Channels.list_channels(),
       filters: %{"tenant_id" => "", "channel_id" => "", "status" => ""},
       page_title: "Conversations"
     )}
  end

  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    filters = Map.merge(socket.assigns.filters, params)

    conversations =
      Converger.Conversations.list_conversations(filters)
      |> Repo.preload([:tenant, :channel])
      |> Enum.sort_by(& &1.inserted_at, :desc)

    assign(socket, conversations: conversations, filters: filters)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    conversation =
      Converger.Conversations.get_conversation!(id)
      |> Repo.preload([:tenant, :channel])

    activities = Activities.list_activities_for_conversation(id)

    # Build delivery status map for all activities
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

    # Subscribe to real-time status updates
    if connected?(socket) do
      ConvergerWeb.Endpoint.subscribe("conversation:#{id}")
    end

    assign(socket,
      conversation: conversation,
      activities: activities,
      delivery_map: delivery_map
    )
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/conversations?#{filters}")}
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

    {:noreply, assign(socket, delivery_map: delivery_map)}
  end

  def handle_info(%{topic: "conversation:" <> _}, socket), do: {:noreply, socket}

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
        <tbody>
          <tr :for={c <- @conversations}>
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
      <table>
        <thead>
          <tr>
            <th>Time</th>
            <th>Sender</th>
            <th>Message</th>
            <th>Delivery</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={a <- @activities}>
            <td style="white-space: nowrap;"><small><%= a.inserted_at %></small></td>
            <td><strong><%= a.sender %></strong></td>
            <td><%= a.text %></td>
            <td><%= delivery_badge(Map.get(@delivery_map, a.id)) %></td>
          </tr>
          <tr :if={Enum.empty?(@activities)}>
            <td colspan="4" style="text-align: center; color: #999;">No activities found</td>
          </tr>
        </tbody>
      </table>
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
