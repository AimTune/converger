defmodule ConvergerWeb.Portal.ConversationLive do
  use ConvergerWeb, :live_view

  import ConvergerWeb.ConversationComponents

  alias Converger.Activities
  alias Converger.Channels
  alias Converger.Conversations
  alias Converger.Pagination.Page
  alias Converger.Repo

  # Conversations are keyset-paginated ("Load more") with URL-driven filters;
  # the transcript opens on the most recent activities with "Load earlier"
  # and is tailed live over PubSub.
  @filter_keys ~w(channel_id status q sort)
  @editor_roles ~w(owner admin member)

  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.current_tenant.id
    channels = Channels.list_channels_for_tenant(tenant_id)

    {:ok,
     socket
     |> assign(
       channels: channels,
       page_title: "Conversations",
       filters: default_filters(),
       can_manage: socket.assigns[:tenant_role] in @editor_roles,
       viewing: nil,
       subscribed_id: nil,
       next_cursor: nil,
       has_more: false,
       loaded_count: 0,
       delivery_map: %{},
       has_older: false,
       oldest_seq: nil,
       newest_seq: nil,
       activity_count: 0
     )
     |> stream(:conversations, [])
     |> stream(:activities, [])}
  end

  defp default_filters, do: %{"channel_id" => "", "status" => "", "q" => "", "sort" => "desc"}

  def handle_params(%{"id" => id}, _uri, socket) do
    tenant_id = socket.assigns.current_tenant.id

    with {:ok, _} <- Ecto.UUID.cast(id),
         %{} = conversation <- Conversations.get_conversation(id, tenant_id) do
      {:noreply,
       socket
       |> subscribe(conversation.id)
       |> assign(viewing: preload_conversation(conversation), page_title: "Conversation")
       |> load_transcript()}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, "Conversation not found")
         |> push_navigate(to: "/portal/conversations")}
    end
  end

  def handle_params(params, _uri, socket) do
    filters = Map.merge(default_filters(), Map.take(params, @filter_keys))

    {:noreply,
     socket
     |> assign(filters: filters, viewing: nil, page_title: "Conversations")
     |> load_conversations(reset: true)}
  end

  defp preload_conversation(conversation) do
    Repo.preload(conversation, [:channel, :participant], force: true)
  end

  defp subscribe(socket, id) do
    old = socket.assigns.subscribed_id

    if connected?(socket) and old != id do
      if old, do: ConvergerWeb.Endpoint.unsubscribe("conversation:#{old}")
      ConvergerWeb.Endpoint.subscribe("conversation:#{id}")
      assign(socket, subscribed_id: id)
    else
      socket
    end
  end

  defp load_transcript(socket) do
    {activities, has_older} = Activities.page_recent_activities(socket.assigns.viewing.id)

    socket
    |> assign(
      delivery_map: delivery_map(activities),
      has_older: has_older,
      oldest_seq: seq_of(List.first(activities), nil),
      newest_seq: seq_of(List.last(activities), nil),
      activity_count: length(activities)
    )
    |> stream(:activities, activities, reset: true)
  end

  defp seq_of(nil, default), do: default
  defp seq_of(%{seq: seq}, _default), do: seq

  def handle_event(action, _params, %{assigns: %{viewing: %{} = conversation}} = socket)
      when action in ["close", "reopen"] do
    if socket.assigns.can_manage do
      change_status(socket, conversation, action)
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}
    end
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    query = filters |> Map.take(@filter_keys) |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
    {:noreply, push_patch(socket, to: "/portal/conversations?#{URI.encode_query(query)}")}
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
          delivery_map: Map.merge(socket.assigns.delivery_map, delivery_map(activities)),
          has_older: has_older,
          oldest_seq: seq_of(List.first(activities), oldest_seq),
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

  defp change_status(socket, conversation, action) do
    opts = [actor: build_actor(socket)]

    result =
      case action do
        "close" -> Conversations.close_conversation(conversation, opts)
        "reopen" -> Conversations.reopen_conversation(conversation, opts)
      end

    case result do
      {:ok, updated} ->
        # Reload the transcript: it now ends with the lifecycle event.
        {:noreply,
         socket
         |> assign(viewing: preload_conversation(updated))
         |> load_transcript()
         |> put_flash(:info, "Conversation #{updated.status}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update conversation")}
    end
  end

  defp build_actor(socket) do
    case socket.assigns[:current_tenant_user] do
      %{email: email} -> %{type: "tenant_user", id: email}
      _ -> %{type: "tenant_user", id: "unknown"}
    end
  end

  def handle_info(
        %{topic: "conversation:" <> id, event: "new_activity", payload: payload},
        %{assigns: %{viewing: %{id: id}}} = socket
      ) do
    {:noreply, tail_activity(socket, struct(Activities.Activity, payload))}
  end

  def handle_info(
        %{topic: "conversation:" <> id, event: "delivery_status", payload: payload},
        %{assigns: %{viewing: %{id: id}}} = socket
      ) do
    socket =
      assign(socket, delivery_map: put_delivery_status(socket.assigns.delivery_map, payload))

    {:noreply, refresh_activity_row(socket, payload.activity_id)}
  end

  def handle_info(%{topic: "conversation:" <> _}, socket), do: {:noreply, socket}

  # Append a live activity, deduplicated on `seq` (after a close/reopen the
  # lifecycle event is both reloaded and broadcast).
  defp tail_activity(socket, activity) do
    newest = socket.assigns.newest_seq
    new? = is_nil(newest) or activity.seq > newest

    socket =
      socket
      |> assign(
        delivery_map: Map.merge(socket.assigns.delivery_map, delivery_map([activity])),
        newest_seq: if(new?, do: activity.seq, else: newest),
        oldest_seq: socket.assigns.oldest_seq || activity.seq,
        activity_count: socket.assigns.activity_count + if(new?, do: 1, else: 0)
      )
      |> stream_insert(:activities, activity)

    # A close/reopen made elsewhere (API, expiry): refresh the status.
    if Conversations.lifecycle_event?(activity) do
      assign(socket, viewing: preload_conversation(socket.assigns.viewing))
    else
      socket
    end
  end

  # Stream rows only re-render when re-inserted.
  defp refresh_activity_row(socket, activity_id) do
    %{viewing: conversation, oldest_seq: oldest, newest_seq: newest} = socket.assigns

    with true <- is_integer(oldest) and is_integer(newest),
         %Activities.Activity{} = activity <- Repo.get(Activities.Activity, activity_id),
         true <- activity.conversation_id == conversation.id,
         true <- activity.seq >= oldest and activity.seq <= newest do
      stream_insert(socket, :activities, activity)
    else
      _ -> socket
    end
  end

  defp load_conversations(socket, reset: reset) do
    %{filters: filters, current_tenant: tenant} = socket.assigns
    scope = filters |> Map.take(~w(channel_id status q)) |> Map.put("tenant_id", tenant.id)
    cursor = if reset, do: nil, else: socket.assigns.next_cursor

    page =
      with {:ok, _} <- valid_channel_filter(scope["channel_id"]),
           {:ok, page} <-
             Conversations.paginate_conversations(scope,
               cursor: cursor,
               direction: sort_direction(filters),
               preload: [:participant]
             ) do
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

  defp sort_direction(%{"sort" => "asc"}), do: :asc
  defp sort_direction(_), do: :desc

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
            <dd id="conversation-status"><.badge value={@viewing.status} /></dd>
          </div>
        </dl>
        <.status_actions :if={@can_manage} conversation={@viewing} />
      </.panel>

      <.participant_panel conversation={@viewing} />

      <.panel title="Activities">
        <:actions><.live_indicator connected={@subscribed_id != nil} /></:actions>
        <div :if={@has_older} class="text-center">
          <.button id="load-older-activities" phx-click="load_older" size="sm" variant="neutral">
            <.icon name="hero-arrow-up" /> Load earlier activities
          </.button>
        </div>
        <ul id="activities" phx-update="stream" class="divide-y divide-base-300">
          <li :for={{dom_id, activity} <- @streams.activities} id={dom_id} class="py-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <span class="font-semibold">{activity.sender || "system"}</span>
              <span class="flex items-center gap-2">
                <.delivery_badge
                  id={"delivery-#{activity.id}"}
                  delivery={Map.get(@delivery_map, activity.id)}
                />
                <span class="text-xs text-base-content/60">
                  {Calendar.strftime(activity.inserted_at, "%Y-%m-%d %H:%M:%S")}
                </span>
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
          <div class="grid items-end gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
            <.input
              type="search"
              id="filter_q"
              name="filters[q]"
              value={@filters["q"]}
              label="Search"
              placeholder="Conversation ID or participant"
              phx-debounce="300"
            />
            <.input
              type="select"
              id="filter_channel_id"
              name="filters[channel_id]"
              value={@filters["channel_id"]}
              label="Channel"
              prompt="All Channels"
              options={Enum.map(@channels, &{&1.name, &1.id})}
            />
            <.input
              type="select"
              id="filter_status"
              name="filters[status]"
              value={@filters["status"]}
              label="Status"
              prompt="All"
              options={[{"Active", "active"}, {"Closed", "closed"}]}
            />
            <.input
              type="select"
              id="filter_sort"
              name="filters[sort]"
              value={@filters["sort"]}
              label="Sort"
              options={[{"Newest first", "desc"}, {"Oldest first", "asc"}]}
            />
          </div>
        </form>

        <div class="overflow-x-auto">
          <.table id="conversations" rows={@streams.conversations}>
            <:col :let={{_id, conv}} label="ID">
              <span class="font-mono text-xs break-all">{conv.id}</span>
            </:col>
            <:col :let={{_id, conv}} label="Participant">
              <.participant_cell participant={conv.participant} />
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
