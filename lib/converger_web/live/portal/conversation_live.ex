defmodule ConvergerWeb.Portal.ConversationLive do
  use ConvergerWeb, :live_view

  alias Converger.Conversations
  alias Converger.Channels
  alias Converger.Activities
  alias Converger.Pagination.Page

  # Conversations are keyset-paginated (newest first, "Load more"); the
  # transcript opens on the most recent activities with "Load earlier".
  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.current_tenant.id
    channels = Channels.list_channels_for_tenant(tenant_id)

    {:ok,
     socket
     |> assign(
       channels: channels,
       page_title: "Conversations",
       filter_channel_id: "",
       filter_status: "",
       viewing: nil,
       next_cursor: nil,
       has_more: false,
       loaded_count: 0,
       has_older: false,
       oldest_seq: nil,
       activity_count: 0
     )
     |> stream(:activities, [])
     |> load_conversations(reset: true)}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    tenant_id = socket.assigns.current_tenant.id

    with {:ok, _} <- Ecto.UUID.cast(id),
         %{} = conversation <- Conversations.get_conversation(id, tenant_id) do
      {activities, has_older} = Activities.page_recent_activities(conversation.id)

      {:noreply,
       socket
       |> assign(
         viewing: conversation,
         page_title: "Conversation",
         has_older: has_older,
         oldest_seq: oldest_seq(activities, nil),
         activity_count: length(activities)
       )
       |> stream(:activities, activities, reset: true)}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, "Conversation not found")
         |> push_navigate(to: "/portal/conversations")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(
       filter_channel_id: Map.get(params, "channel_id", socket.assigns.filter_channel_id),
       filter_status: Map.get(params, "status", socket.assigns.filter_status)
     )
     |> load_conversations(reset: true)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply, load_conversations(socket, reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("load_older", _params, socket) do
    %{viewing: conversation, oldest_seq: oldest_seq, has_older: has_older} = socket.assigns

    if conversation && has_older && is_integer(oldest_seq) do
      {activities, has_older} =
        Activities.page_recent_activities(conversation.id, before_seq: oldest_seq)

      socket =
        assign(socket,
          has_older: has_older,
          oldest_seq: oldest_seq(activities, oldest_seq),
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

  defp oldest_seq([first | _], _default), do: first.seq
  defp oldest_seq([], default), do: default

  defp load_conversations(socket, reset: reset) do
    filters =
      %{
        "tenant_id" => socket.assigns.current_tenant.id,
        "channel_id" => socket.assigns.filter_channel_id,
        "status" => socket.assigns.filter_status
      }

    cursor = if reset, do: nil, else: socket.assigns.next_cursor

    page =
      with {:ok, _} <- valid_channel_filter(filters["channel_id"]),
           {:ok, page} <- Conversations.paginate_conversations(filters, cursor: cursor) do
        page
      else
        _ -> %Page{}
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

  defp valid_channel_filter(""), do: {:ok, ""}
  defp valid_channel_filter(id), do: Ecto.UUID.cast(id)

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
      <div :if={@has_older} style="text-align: center; margin-bottom: 10px;">
        <button id="load-older-activities" phx-click="load_older"
          style="padding: 6px 12px; border: 1px solid #ddd; border-radius: 4px; background: white; cursor: pointer;">
          &uarr; Load earlier activities
        </button>
      </div>
      <div id="activities" phx-update="stream">
        <div :for={{dom_id, activity} <- @streams.activities} id={dom_id} style="padding: 10px; border-bottom: 1px solid #eee;">
          <div style="display: flex; justify-content: space-between; align-items: center;">
            <strong><%= activity.sender || "system" %></strong>
            <small style="color: #999;"><%= Calendar.strftime(activity.inserted_at, "%Y-%m-%d %H:%M:%S") %></small>
          </div>
          <p style="margin: 5px 0;"><%= activity.text %></p>
        </div>
      </div>
      <p :if={@activity_count == 0} style="color: #999; text-align: center;">No activities yet.</p>
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
        <tbody id="conversations" phx-update="stream">
          <tr :for={{dom_id, conv} <- @streams.conversations} id={dom_id}>
            <td><small><%= conv.id %></small></td>
            <td><span class={"badge badge-#{conv.status}"}><%= conv.status %></span></td>
            <td><small><%= Calendar.strftime(conv.inserted_at, "%Y-%m-%d %H:%M") %></small></td>
            <td>
              <a href={~p"/portal/conversations/#{conv.id}"} style="color: #2e7d32; text-decoration: none;">View</a>
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@loaded_count == 0} style="text-align: center; color: #999;">No conversations found.</p>
      <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 10px;">
        <small style="color: #666;">Showing <%= @loaded_count %> conversations</small>
        <button :if={@has_more} id="load-more-conversations" phx-click="load_more"
          style="padding: 6px 12px; border: 1px solid #ddd; border-radius: 4px; background: white; cursor: pointer;">
          Load more
        </button>
      </div>
    </div>
    """
  end
end
