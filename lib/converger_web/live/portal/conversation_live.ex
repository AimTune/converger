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

  def handle_event(action, _params, %{assigns: %{viewing: %{} = conversation}} = socket)
      when action in ["close", "reopen"] do
    result =
      case action do
        "close" -> Conversations.close_conversation(conversation)
        "reopen" -> Conversations.reopen_conversation(conversation)
      end

    case result do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(
           viewing: updated,
           activities: Activities.list_activities_for_conversation(updated.id)
         )
         |> put_flash(:info, "Conversation #{updated.status}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update conversation")}
    end
  end

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
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Conversation Detail
        <:subtitle><span class="font-mono text-xs break-all">{@viewing.id}</span></:subtitle>
        <:actions>
          <.button href={~p"/portal/conversations"} size="sm" variant="ghost">
            <.icon name="hero-arrow-left" /> Back to Conversations
          </.button>
        </:actions>
      </.header>

      <.panel>
        <dl class="grid gap-4 sm:grid-cols-2">
          <div>
            <dt class="text-sm text-base-content/60">ID</dt>
            <dd><code class="font-mono text-xs break-all">{@viewing.id}</code></dd>
          </div>
          <div>
            <dt class="text-sm text-base-content/60">Status</dt>
            <dd><.badge value={@viewing.status} /></dd>
          </div>
        </dl>
        <div>
          <.button
            :if={@viewing.status == "active"}
            id="close-conversation"
            phx-click="close"
            data-confirm="Close this conversation? It will stop accepting activities."
            size="sm"
            variant="error"
          >
            Close conversation
          </.button>
          <.button
            :if={@viewing.status == "closed"}
            id="reopen-conversation"
            phx-click="reopen"
            size="sm"
            variant="neutral"
          >
            Reopen conversation
          </.button>
        </div>
      </.panel>

      <.panel title="Activities">
        <div :if={@has_older} class="text-center">
          <.button id="load-older-activities" phx-click="load_older" size="sm" variant="neutral">
            <.icon name="hero-arrow-up" /> Load earlier activities
          </.button>
        </div>
        <ul id="activities" phx-update="stream" class="divide-y divide-base-300">
          <li :for={{dom_id, activity} <- @streams.activities} id={dom_id} class="py-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <span class="font-semibold">{activity.sender || "system"}</span>
              <span class="text-xs text-base-content/60">
                {Calendar.strftime(activity.inserted_at, "%Y-%m-%d %H:%M:%S")}
              </span>
            </div>
            <p class="mt-1 break-words">{activity.text}</p>
          </li>
        </ul>
        <.empty_state :if={@activity_count == 0}>No activities yet.</.empty_state>
      </.panel>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Conversations
        <:subtitle>Conversations on {@current_tenant.name}'s channels.</:subtitle>
      </.header>

      <.panel>
        <form id="portal-conversation-filter" phx-change="filter">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
            <.input
              type="select"
              id="filter_channel_id"
              name="channel_id"
              value={@filter_channel_id}
              label="Channel"
              prompt="All Channels"
              options={Enum.map(@channels, &{&1.name, &1.id})}
            />
            <.input
              type="select"
              id="filter_status"
              name="status"
              value={@filter_status}
              label="Status"
              prompt="All"
              options={[{"Active", "active"}, {"Closed", "closed"}]}
            />
          </div>
        </form>

        <div class="overflow-x-auto">
          <.table id="conversations" rows={@streams.conversations}>
            <:col :let={{_id, conv}} label="ID">
              <span class="font-mono text-xs break-all">{conv.id}</span>
            </:col>
            <:col :let={{_id, conv}} label="Status"><.badge value={conv.status} /></:col>
            <:col :let={{_id, conv}} label="Created">
              <span class="text-xs whitespace-nowrap">
                {Calendar.strftime(conv.inserted_at, "%Y-%m-%d %H:%M")}
              </span>
            </:col>
            <:action :let={{_id, conv}}>
              <.button href={~p"/portal/conversations/#{conv.id}"} size="xs" variant="neutral">
                View
              </.button>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@loaded_count == 0}>No conversations found.</.empty_state>
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
end
