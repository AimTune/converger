defmodule ConvergerWeb.Live.WebhooksPage do
  @moduledoc """
  Shared implementation of the admin (`/admin/webhooks`) and portal
  (`/portal/webhooks`) platform event webhook pages (ADR-0053): the
  subscriptions (searchable by URL), a create form and "Rotate secret" (the
  signing secret is shown once), enable, disable and delete, and the recent
  events with their status and a
  "Redeliver" button for dead-lettered (`failed`) events, keyset-paged with
  "Load more".

  Options passed by the two LiveViews:

    * `:tenant_id` - forced tenant scope (portal), or `nil` (admin, all tenants)
    * `:can_edit` - whether the user may change subscriptions and redeliver
    * `:actor` - audit actor (`%{type: ..., id: ...}`)
    * `:tenants` - tenants offered when creating (admin only), or `nil`
  """
  use ConvergerWeb, :html

  import Phoenix.LiveView

  alias Converger.Webhooks
  alias Converger.Webhooks.{Catalog, Event, Subscription}

  @recent_events 50

  def mount(socket, opts) do
    socket
    |> assign(
      page_title: "Webhooks",
      scope_tenant_id: Keyword.get(opts, :tenant_id),
      can_edit: Keyword.fetch!(opts, :can_edit),
      actor: Keyword.fetch!(opts, :actor),
      tenants: Keyword.get(opts, :tenants),
      event_types: Catalog.types(),
      new_secret: nil,
      form_errors: [],
      event_filters: %{"status" => "", "subscription_id" => ""},
      subscription_query: "",
      events: [],
      events_cursor: nil,
      events_has_more: false
    )
    |> load()
  end

  @doc """
  Applies the subscription search kept in the URL (`?q=`), so a filtered view
  can be bookmarked like the other admin/portal lists.
  """
  def handle_params(params, socket) do
    query = Map.get(params, "q", "")

    {:noreply,
     assign(socket,
       subscription_query: query,
       subscriptions: search_subscriptions(socket.assigns.all_subscriptions, query)
     )}
  end

  def handle_event("create", %{"subscription" => params}, socket) do
    with :ok <- authorize(socket),
         {:ok, tenant_id} <- create_tenant_id(socket, params["tenant_id"]) do
      attrs = %{
        "url" => params["url"],
        "description" => params["description"],
        "events" => Map.get(params, "events", [])
      }

      case Webhooks.create_subscription(tenant_id, attrs, socket.assigns.actor) do
        {:ok, subscription} ->
          {:noreply,
           socket
           |> assign(
             new_secret: %{id: subscription.id, secret: subscription.secret},
             form_errors: []
           )
           |> put_flash(:info, "Subscription created. Copy the signing secret now.")
           |> load()}

        {:error, changeset} ->
          {:noreply, assign(socket, form_errors: errors(changeset))}
      end
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with :ok <- authorize(socket),
         {:ok, subscription} <- fetch_subscription(socket, id),
         {:ok, _} <-
           Webhooks.update_subscription(
             subscription,
             %{enabled: !subscription.enabled},
             socket.assigns.actor
           ) do
      {:noreply, socket |> put_flash(:info, "Subscription updated") |> load()}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update subscription")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with :ok <- authorize(socket),
         {:ok, subscription} <- fetch_subscription(socket, id),
         {:ok, _} <- Webhooks.delete_subscription(subscription, socket.assigns.actor) do
      {:noreply, socket |> put_flash(:info, "Subscription deleted") |> load()}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to delete subscription")}
    end
  end

  def handle_event("redeliver", %{"id" => id}, socket) do
    with :ok <- authorize(socket),
         {:ok, event} <- fetch_event(socket, id) do
      case Webhooks.redeliver(event, socket.assigns.actor) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, "Event queued for redelivery") |> load()}

        {:error, :not_failed} ->
          {:noreply, put_flash(socket, :error, "Only failed events can be redelivered")}
      end
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("rotate_secret", %{"id" => id}, socket) do
    with :ok <- authorize(socket),
         {:ok, subscription} <- fetch_subscription(socket, id),
         {:ok, subscription} <-
           Webhooks.update_subscription(
             subscription,
             %{"secret" => Subscription.generate_secret()},
             socket.assigns.actor
           ) do
      {:noreply,
       socket
       |> assign(new_secret: %{id: subscription.id, secret: subscription.secret})
       |> put_flash(:info, "Signing secret rotated. Copy the new secret now.")
       |> load()}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to rotate the secret")}
    end
  end

  def handle_event("filter_events", %{"events" => filters}, socket) do
    filters = Map.take(filters, ["status", "subscription_id"])
    {:noreply, socket |> assign(event_filters: filters) |> load_events(reset: true)}
  end

  def handle_event("load_more_events", _params, socket) do
    if socket.assigns.events_has_more,
      do: {:noreply, load_events(socket, reset: false)},
      else: {:noreply, socket}
  end

  def handle_event("search_subscriptions", %{"subscriptions" => %{"q" => query}}, socket) do
    path = socket.assigns.nav.path

    to =
      if String.trim(query) == "",
        do: path,
        else: path <> "?" <> URI.encode_query(%{"q" => query})

    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("dismiss_secret", _params, socket),
    do: {:noreply, assign(socket, new_secret: nil)}

  defp authorize(%{assigns: %{can_edit: true}}), do: :ok
  defp authorize(_socket), do: {:error, "You don't have permission to do this."}

  defp create_tenant_id(%{assigns: %{scope_tenant_id: tenant_id}}, _param)
       when is_binary(tenant_id),
       do: {:ok, tenant_id}

  defp create_tenant_id(_socket, param) do
    case Ecto.UUID.cast(param || "") do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "Select a tenant"}
    end
  end

  defp fetch_subscription(socket, id) do
    subscription = Webhooks.get_subscription!(id)

    if in_scope?(socket, subscription.tenant_id),
      do: {:ok, subscription},
      else: {:error, "Unauthorized"}
  rescue
    Ecto.NoResultsError -> {:error, "Subscription not found"}
    Ecto.Query.CastError -> {:error, "Subscription not found"}
  end

  defp fetch_event(socket, id) do
    event = Webhooks.get_event!(id)
    if in_scope?(socket, event.tenant_id), do: {:ok, event}, else: {:error, "Unauthorized"}
  rescue
    Ecto.NoResultsError -> {:error, "Event not found"}
    Ecto.Query.CastError -> {:error, "Event not found"}
  end

  defp in_scope?(%{assigns: %{scope_tenant_id: nil}}, _tenant_id), do: true
  defp in_scope?(%{assigns: %{scope_tenant_id: scope}}, tenant_id), do: scope == tenant_id

  # Subscriptions are a small, bounded list (`Converger.Pagination.bounded_all/2`),
  # so the search box filters them in memory; the event log is keyset-paged
  # ("Load more").
  defp load(socket) do
    scope = socket.assigns.scope_tenant_id

    subscriptions =
      if scope,
        do: Webhooks.list_subscriptions(scope),
        else: Webhooks.list_all_subscriptions()

    socket
    |> assign(
      all_subscriptions: subscriptions,
      subscriptions: search_subscriptions(subscriptions, socket.assigns.subscription_query),
      subscription_urls: Map.new(subscriptions, &{&1.id, &1.url})
    )
    |> load_events(reset: true)
  end

  defp search_subscriptions(subscriptions, query) do
    case String.trim(query || "") do
      "" ->
        subscriptions

      term ->
        term = String.downcase(term)
        Enum.filter(subscriptions, &String.contains?(String.downcase(&1.url), term))
    end
  end

  defp load_events(socket, reset: reset) do
    filters = socket.assigns.event_filters
    cursor = if reset, do: nil, else: socket.assigns.events_cursor

    event_filters = %{
      tenant_id: socket.assigns.scope_tenant_id,
      status: blank_to_nil(filters["status"]),
      subscription_id: uuid_or_nil(filters["subscription_id"])
    }

    page =
      case Webhooks.paginate_events(event_filters, limit: @recent_events, cursor: cursor) do
        {:ok, page} -> page
        {:error, :invalid_cursor} -> %Converger.Pagination.Page{}
      end

    events = if reset, do: page.entries, else: socket.assigns.events ++ page.entries

    assign(socket,
      events: events,
      events_cursor: page.next_cursor,
      events_has_more: page.has_more
    )
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp uuid_or_nil(value) do
    case Ecto.UUID.cast(value || "") do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
  end

  defp format_timestamp(nil), do: "-"
  defp format_timestamp(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp tenant_name(%{tenant: %{name: name}}), do: name
  defp tenant_name(_), do: ""

  defp status_options, do: [{"All statuses", ""} | Enum.map(Event.statuses(), &{&1, &1})]

  defp subscription_options(subscriptions),
    do: [{"All subscriptions", ""} | Enum.map(subscriptions, &{&1.url, &1.id})]

  defp tenant_options(tenants),
    do: [{"Select a tenant", ""} | Enum.map(tenants, &{&1.name, &1.id})]

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Webhooks
        <:subtitle>
          Platform event webhooks: Converger POSTs signed events (activities, delivery
          status, conversations, channel health) to these URLs.
        </:subtitle>
      </.header>

      <div :if={@new_secret} id="new-webhook-secret" role="alert" class="alert alert-warning items-start">
        <.icon name="hero-key" class="size-6 shrink-0" />
        <div class="min-w-0 flex-1 space-y-2">
          <h3 class="font-semibold">Signing secret</h3>
          <p class="text-sm">Shown once, store it now.</p>
          <code class="block rounded bg-base-100 p-2 font-mono text-sm break-all text-base-content">{@new_secret.secret}</code>
          <.button type="button" phx-click="dismiss_secret" size="sm" variant="neutral">Done</.button>
        </div>
      </div>

      <.panel :if={@can_edit} title="New subscription">
        <form phx-submit="create" id="webhook-subscription-form">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-3">
            <.input
              :if={@tenants}
              type="select"
              id="webhook-subscription-tenant"
              name="subscription[tenant_id]"
              label="Tenant"
              value=""
              options={tenant_options(@tenants)}
            />
            <.input
              type="url"
              id="webhook-subscription-url"
              name="subscription[url]"
              label="URL"
              value=""
              placeholder="https://example.com/converger-events"
            />
            <.input
              type="text"
              id="webhook-subscription-description"
              name="subscription[description]"
              label="Description"
              value=""
            />
          </div>
          <fieldset class="fieldset mb-2">
            <legend class="label mb-1">Events</legend>
            <div class="flex flex-wrap gap-x-4 gap-y-2">
              <label class="label cursor-pointer gap-2 text-sm">
                <input type="checkbox" name="subscription[events][]" value="*" class="checkbox checkbox-sm" />
                all (<code class="font-mono text-xs">*</code>)
              </label>
              <label :for={type <- @event_types} class="label cursor-pointer gap-2 text-sm">
                <input type="checkbox" name="subscription[events][]" value={type} class="checkbox checkbox-sm" />
                <code class="font-mono text-xs">{type}</code>
              </label>
            </div>
          </fieldset>
          <ul :if={@form_errors != []} class="mb-2 list-disc pl-5 text-sm text-error">
            <li :for={error <- @form_errors}>{error}</li>
          </ul>
          <.button type="submit" variant="primary">Create subscription</.button>
        </form>
      </.panel>

      <.panel title="Subscriptions">
        <form phx-change="search_subscriptions" id="webhook-subscription-search">
          <.input
            type="search"
            id="webhook-subscription-search-q"
            name="subscriptions[q]"
            label="Search"
            value={@subscription_query}
            placeholder="URL contains..."
            phx-debounce="300"
          />
        </form>
        <div class="overflow-x-auto">
          <.table id="webhook-subscriptions" rows={@subscriptions} row_id={&"subscription-#{&1.id}"}>
            <:col :let={s} :if={@tenants} label="Tenant">{tenant_name(s)}</:col>
            <:col :let={s} label="URL">
              <div class="max-w-80 break-all font-mono text-xs">{s.url}</div>
              <div :if={s.description} class="text-xs text-base-content/60">{s.description}</div>
              <.badge
                :if={s.managed_by}
                value={s.managed_by}
                class="mt-1"
                title="Maintained from the tenant's alert webhook URL"
              />
            </:col>
            <:col :let={s} label="Events">
              <div class="flex flex-wrap gap-1">
                <.badge :for={type <- s.events} value={type} class="font-mono" />
              </div>
            </:col>
            <:col :let={s} label="Status">
              <.badge value={if s.enabled, do: "enabled", else: "disabled"} />
            </:col>
            <:action :let={s} :if={@can_edit}>
              <.button phx-click="toggle" phx-value-id={s.id} size="xs" variant="neutral">
                {if s.enabled, do: "Disable", else: "Enable"}
              </.button>
              <.button
                id={"rotate-secret-#{s.id}"}
                phx-click="rotate_secret"
                phx-value-id={s.id}
                data-confirm="Rotate the signing secret? The current secret stops working immediately."
                size="xs"
                variant="neutral"
              >
                Rotate secret
              </.button>
              <.button
                phx-click="delete"
                phx-value-id={s.id}
                data-confirm="Delete this subscription and its event log?"
                size="xs"
                variant="error"
              >
                Delete
              </.button>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@all_subscriptions == []}>No subscriptions yet.</.empty_state>
        <.empty_state :if={@all_subscriptions != [] and @subscriptions == []}>
          No subscriptions match the search.
        </.empty_state>
      </.panel>

      <.panel title="Recent events">
        <form phx-change="filter_events" id="webhook-event-filter">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-3">
            <.input
              type="select"
              id="webhook-event-filter-status"
              name="events[status]"
              label="Status"
              value={@event_filters["status"]}
              options={status_options()}
            />
            <.input
              type="select"
              id="webhook-event-filter-subscription"
              name="events[subscription_id]"
              label="Subscription"
              value={@event_filters["subscription_id"]}
              options={subscription_options(@all_subscriptions)}
            />
          </div>
        </form>
        <div class="overflow-x-auto">
          <.table id="webhook-events" rows={@events} row_id={&"webhook-event-#{&1.id}"}>
            <:col :let={e} label="Time">
              <span class="whitespace-nowrap text-xs">{format_timestamp(e.inserted_at)}</span>
            </:col>
            <:col :let={e} label="Type"><code class="font-mono text-xs">{e.type}</code></:col>
            <:col :let={e} label="Subscription">
              <span class="block max-w-60 break-all text-xs">
                {Map.get(@subscription_urls, e.subscription_id, e.subscription_id)}
              </span>
            </:col>
            <:col :let={e} label="Status"><.badge value={e.status} /></:col>
            <:col :let={e} label="Attempts">{e.attempts}</:col>
            <:col :let={e} label="Last error">
              <span class="block max-w-72 break-all text-xs text-error">{e.last_error}</span>
            </:col>
            <:action :let={e} :if={@can_edit}>
              <.button
                :if={e.status == "failed"}
                phx-click="redeliver"
                phx-value-id={e.id}
                size="xs"
                variant="neutral"
              >
                Redeliver
              </.button>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@events == []}>No events.</.empty_state>
        <div class="flex items-center justify-between gap-2">
          <span class="text-sm text-base-content/60">Showing {length(@events)} events</span>
          <.button
            :if={@events_has_more}
            id="load-more-webhook-events"
            phx-click="load_more_events"
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
