defmodule ConvergerWeb.Portal.ConversationLive do
  use ConvergerWeb, :live_view

  alias Converger.Conversations
  alias Converger.Channels
  alias Converger.Activities

  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.current_tenant.id
    channels = Channels.list_channels_for_tenant(tenant_id)

    {:ok,
     assign(socket,
       conversations: Conversations.list_conversations_for_tenant(tenant_id),
       channels: channels,
       page_title: "Conversations",
       filter_channel_id: "",
       filter_status: "",
       viewing: nil,
       activities: []
     )}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    tenant_id = socket.assigns.current_tenant.id

    case Conversations.get_conversation(id, tenant_id) do
      nil ->
        {:noreply,
         put_flash(socket, :error, "Conversation not found")
         |> push_navigate(to: "/portal/conversations")}

      conversation ->
        activities = Activities.list_activities_for_conversation(conversation.id)

        {:noreply,
         assign(socket, viewing: conversation, activities: activities, page_title: "Conversation")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("filter", params, socket) do
    tenant_id = socket.assigns.current_tenant.id
    channel_id = Map.get(params, "channel_id", "")
    status = Map.get(params, "status", "")

    filters =
      %{"tenant_id" => tenant_id}
      |> then(fn f -> if channel_id != "", do: Map.put(f, "channel_id", channel_id), else: f end)
      |> then(fn f -> if status != "", do: Map.put(f, "status", status), else: f end)

    {:noreply,
     assign(socket,
       conversations: Conversations.list_conversations(filters),
       filter_channel_id: channel_id,
       filter_status: status
     )}
  end

  def render(%{viewing: %{} = _conversation} = assigns) do
    ~H"""
    <div style="margin-bottom: 15px;">
      <a href={~p"/portal/conversations"} style="color: #2e7d32; text-decoration: none;">&larr; Back to Conversations</a>
    </div>

    <h1>Conversation Detail</h1>

    <div class="card">
      <p><strong>ID:</strong> <small><%= @viewing.id %></small></p>
      <p><strong>Status:</strong> <span class={"badge badge-#{@viewing.status}"}><%= @viewing.status %></span></p>
    </div>

    <h2>Activities</h2>
    <div class="card">
      <div :for={activity <- @activities} style="padding: 10px; border-bottom: 1px solid #eee;">
        <div style="display: flex; justify-content: space-between; align-items: center;">
          <strong><%= activity.sender || "system" %></strong>
          <small style="color: #999;"><%= Calendar.strftime(activity.inserted_at, "%Y-%m-%d %H:%M:%S") %></small>
        </div>
        <p style="margin: 5px 0;"><%= activity.text %></p>
      </div>
      <p :if={@activities == []} style="color: #999; text-align: center;">No activities yet.</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <h1>Conversations</h1>

    <div class="card">
      <div style="display: flex; gap: 10px; align-items: flex-end; margin-bottom: 15px;">
        <div>
          <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Channel</label>
          <select phx-change="filter" name="channel_id"
            style="padding: 6px; border: 1px solid #ddd; border-radius: 4px;">
            <option value="">All Channels</option>
            <option :for={c <- @channels} value={c.id} selected={c.id == @filter_channel_id}><%= c.name %></option>
          </select>
        </div>
        <div>
          <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Status</label>
          <select phx-change="filter" name="status"
            style="padding: 6px; border: 1px solid #ddd; border-radius: 4px;">
            <option value="">All</option>
            <option value="active" selected={@filter_status == "active"}>Active</option>
            <option value="closed" selected={@filter_status == "closed"}>Closed</option>
          </select>
        </div>
      </div>

      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Status</th>
            <th>Created</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={conv <- @conversations}>
            <td><small><%= conv.id %></small></td>
            <td><span class={"badge badge-#{conv.status}"}><%= conv.status %></span></td>
            <td><small><%= Calendar.strftime(conv.inserted_at, "%Y-%m-%d %H:%M") %></small></td>
            <td>
              <a href={~p"/portal/conversations/#{conv.id}"} style="color: #2e7d32; text-decoration: none;">View</a>
            </td>
          </tr>
          <tr :if={@conversations == []}>
            <td colspan="4" style="text-align: center; color: #999;">No conversations found.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
