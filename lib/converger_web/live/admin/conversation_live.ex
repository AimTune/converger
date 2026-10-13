defmodule ConvergerWeb.Admin.ConversationLive do
  use ConvergerWeb, :live_view

  import ConvergerWeb.ConversationComponents

  alias Converger.Activities
  alias Converger.Channels
  alias Converger.Conversations
  alias Converger.Repo
  alias Converger.Tenants

  @filter_keys ~w(tenant_id channel_id status q sort per_page)
  @per_page_options [25, 50, 100]
  @manager_roles ~w(super_admin admin)

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       tenants: Tenants.list_tenants(),
       channels: Channels.list_channels(),
       filters: default_filters(),
       per_page_options: @per_page_options,
       can_manage: socket.assigns[:admin_role] in @manager_roles,
       subscribed_id: nil,
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
    |> assign(filters: filters, next_cursor: nil, loaded_count: 0, page_title: "Conversations")
    |> load_conversations(reset: true)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    conversation = id |> Conversations.get_conversation!() |> preload_conversation()

    # Live tail: new activities and delivery status updates.
    socket
    |> subscribe(conversation.id)
    |> assign(conversation: conversation, page_title: "Conversation")
    |> load_transcript()
  end

  defp preload_conversation(conversation) do
    Repo.preload(conversation, [:tenant, :channel, :participant], force: true)
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

  # Open on the most recent page; older activities load on demand.
  defp load_transcript(socket) do
    {activities, has_older} = Activities.page_recent_activities(socket.assigns.conversation.id)

    socket
    |> assign(
      delivery_map: delivery_map(activities),
      has_older: has_older,
      oldest_seq: activities |> List.first() |> seq_or(nil),
      newest_seq: activities |> List.last() |> seq_or(nil),
      activity_count: length(activities)
    )
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
      case Conversations.paginate_conversations(
             Map.take(filters, ~w(tenant_id channel_id status q)),
             cursor: cursor,
             limit: per_page(filters),
             direction: sort_direction(filters),
             preload: [:tenant, :channel, :participant]
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
        assign(socket,
          delivery_map: Map.merge(socket.assigns.delivery_map, delivery_map(activities)),
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

  def handle_event(action, _params, %{assigns: %{live_action: :show}} = socket)
      when action in ["close", "reopen"] do
    if socket.assigns.can_manage do
      change_status(socket, action)
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}
    end
  end

  defp change_status(socket, action) do
    conversation = socket.assigns.conversation
    opts = [actor: build_actor(socket)]

    result =
      case action do
        "close" -> Conversations.close_conversation(conversation, opts)
        "reopen" -> Conversations.reopen_conversation(conversation, opts)
      end

    case result do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(conversation: preload_conversation(updated))
         |> load_transcript()
         |> put_flash(:info, "Conversation #{updated.status}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update conversation")}
    end
  end

  defp build_actor(socket) do
    case socket.assigns[:current_admin_user] do
      %{email: email} -> %{type: "admin", id: email}
      _ -> %{type: "admin", id: "unknown"}
    end
  end

  def handle_info(
        %{topic: "conversation:" <> id, event: "new_activity", payload: payload},
        %{assigns: %{live_action: :show, conversation: %{id: id}}} = socket
      ) do
    {:noreply, tail_activity(socket, struct(Activities.Activity, payload))}
  end

  def handle_info(
        %{topic: "conversation:" <> id, event: "delivery_status", payload: payload},
        %{assigns: %{live_action: :show, conversation: %{id: id}}} = socket
      ) do
    socket =
      assign(socket, delivery_map: put_delivery_status(socket.assigns.delivery_map, payload))

    # Stream rows only re-render when re-inserted; refresh the row if it is
    # within the loaded window.
    {:noreply, refresh_activity_row(socket, payload.activity_id)}
  end

  def handle_info(%{topic: "conversation:" <> _}, socket), do: {:noreply, socket}

  # Append a live activity. Deduplicated on `seq`: after a close/reopen the
  # lifecycle event is both reloaded and broadcast.
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
      assign(socket, conversation: preload_conversation(socket.assigns.conversation))
    else
      socket
    end
  end

  defp refresh_activity_row(socket, activity_id) do
    %{conversation: conversation, oldest_seq: oldest, newest_seq: newest} = socket.assigns

    with true <- is_integer(oldest) and is_integer(newest),
         %Activities.Activity{} = activity <- Repo.get(Activities.Activity, activity_id),
         true <- activity.conversation_id == conversation.id,
         true <- activity.seq >= oldest and activity.seq <= newest do
      stream_insert(socket, :activities, activity)
    else
      _ -> socket
    end
  end

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
              type="search"
              id="filters_q"
              name="filters[q]"
              value={@filters["q"]}
              label="Search"
              placeholder="Conversation ID or participant"
              phx-debounce="300"
            />
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
            <:col :let={{_id, c}} label="Participant">
              <.participant_cell participant={c.participant} />
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
            <dd id="conversation-status"><.badge value={@conversation.status} /></dd>
          </div>
        </dl>
        <.status_actions :if={@can_manage} conversation={@conversation} />
      </.panel>

      <.participant_panel conversation={@conversation} />

      <.panel title="Events (Activities)">
        <:actions><.live_indicator connected={@subscribed_id != nil} /></:actions>
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
                <td>
                  <.delivery_badge id={"delivery-#{a.id}"} delivery={Map.get(@delivery_map, a.id)} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <.empty_state :if={@activity_count == 0}>No activities found</.empty_state>
      </.panel>
    </Layouts.app>
    """
  end
end
