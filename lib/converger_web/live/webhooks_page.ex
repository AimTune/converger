defmodule ConvergerWeb.Live.WebhooksPage do
  @moduledoc """
  Shared implementation of the admin (`/admin/webhooks`) and portal
  (`/portal/webhooks`) platform event webhook pages (ADR-0053): the
  subscriptions, a create form (the signing secret is shown once), enable,
  disable and delete, and the recent events with their status and a
  "Redeliver" button for dead-lettered (`failed`) events.

  Options passed by the two LiveViews:

    * `:tenant_id` - forced tenant scope (portal), or `nil` (admin, all tenants)
    * `:can_edit` - whether the user may change subscriptions and redeliver
    * `:actor` - audit actor (`%{type: ..., id: ...}`)
    * `:tenants` - tenants offered when creating (admin only), or `nil`
  """
  use ConvergerWeb, :html

  import Phoenix.LiveView

  alias Converger.Webhooks
  alias Converger.Webhooks.{Catalog, Event}

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
      event_filters: %{"status" => "", "subscription_id" => ""}
    )
    |> load()
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

  def handle_event("filter_events", %{"events" => filters}, socket) do
    filters = Map.take(filters, ["status", "subscription_id"])
    {:noreply, socket |> assign(event_filters: filters) |> load()}
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

  defp load(socket) do
    scope = socket.assigns.scope_tenant_id

    subscriptions =
      if scope,
        do: Webhooks.list_subscriptions(scope),
        else: Webhooks.list_all_subscriptions()

    filters = socket.assigns.event_filters

    event_filters = %{
      tenant_id: scope,
      status: blank_to_nil(filters["status"]),
      subscription_id: uuid_or_nil(filters["subscription_id"])
    }

    assign(socket,
      subscriptions: subscriptions,
      subscription_urls: Map.new(subscriptions, &{&1.id, &1.url}),
      events: Webhooks.list_recent_events(event_filters, @recent_events)
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

  defp status_badge_class("failed"), do: "badge-inactive"
  defp status_badge_class("delivered"), do: "badge-active"
  defp status_badge_class(_), do: ""

  defp format_timestamp(nil), do: "-"
  defp format_timestamp(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp tenant_name(%{tenant: %{name: name}}), do: name
  defp tenant_name(_), do: ""

  @input_style "padding: 6px; border: 1px solid #ddd; border-radius: 4px;"

  def render(assigns) do
    assigns = assign(assigns, input_style: @input_style, statuses: Event.statuses())

    ~H"""
    <h1>Webhooks</h1>
    <p style="color: #666;">
      Platform event webhooks: Converger POSTs signed events (activities, delivery
      status, conversations, channel health) to these URLs.
    </p>

    <div :if={@new_secret} class="card" id="new-webhook-secret" style="border: 1px solid #f0ad4e;">
      <strong>Signing secret</strong> (shown once, store it now):
      <code style="word-break: break-all;">{@new_secret.secret}</code>
      <button type="button" phx-click="dismiss_secret" class="badge">Done</button>
    </div>

    <div :if={@can_edit} class="card">
      <h3 style="margin-top: 0;">New subscription</h3>
      <form phx-submit="create" id="webhook-subscription-form">
        <div :if={@tenants} style="margin-bottom: 8px;">
          <label>Tenant</label>
          <select name="subscription[tenant_id]" style={@input_style}>
            <option value="">Select a tenant</option>
            <option :for={t <- @tenants} value={t.id}>{t.name}</option>
          </select>
        </div>
        <div style="margin-bottom: 8px;">
          <label>URL</label>
          <input
            type="url"
            name="subscription[url]"
            placeholder="https://example.com/converger-events"
            style={@input_style <> " width: 420px;"}
          />
        </div>
        <div style="margin-bottom: 8px;">
          <label>Description</label>
          <input type="text" name="subscription[description]" style={@input_style <> " width: 420px;"} />
        </div>
        <div style="margin-bottom: 8px;">
          <label>Events</label>
          <div style="display: flex; flex-wrap: wrap; gap: 10px;">
            <label style="font-weight: normal;">
              <input type="checkbox" name="subscription[events][]" value="*" /> all (<code>*</code>)
            </label>
            <label :for={type <- @event_types} style="font-weight: normal;">
              <input type="checkbox" name="subscription[events][]" value={type} /> <code>{type}</code>
            </label>
          </div>
        </div>
        <ul :if={@form_errors != []} style="color: #dc3545;">
          <li :for={error <- @form_errors}>{error}</li>
        </ul>
        <button type="submit">Create subscription</button>
      </form>
    </div>

    <div class="card">
      <h3 style="margin-top: 0;">Subscriptions</h3>
      <table id="webhook-subscriptions">
        <thead>
          <tr>
            <th :if={@tenants}>Tenant</th>
            <th>URL</th>
            <th>Events</th>
            <th>Status</th>
            <th :if={@can_edit}>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={s <- @subscriptions} id={"subscription-#{s.id}"}>
            <td :if={@tenants}>{tenant_name(s)}</td>
            <td style="max-width: 320px; word-break: break-all;">
              {s.url}
              <div :if={s.description} style="color: #888; font-size: 0.85em;">{s.description}</div>
              <span :if={s.managed_by} class="badge" title="Maintained from the tenant's alert webhook URL">
                {s.managed_by}
              </span>
            </td>
            <td>
              <span :for={type <- s.events} class="badge" style="margin-right: 4px;">{type}</span>
            </td>
            <td>
              <span class={"badge badge-#{if s.enabled, do: "active", else: "inactive"}"}>
                {if s.enabled, do: "enabled", else: "disabled"}
              </span>
            </td>
            <td :if={@can_edit} style="white-space: nowrap;">
              <button phx-click="toggle" phx-value-id={s.id} class="badge">
                {if s.enabled, do: "Disable", else: "Enable"}
              </button>
              <button
                phx-click="delete"
                phx-value-id={s.id}
                class="badge"
                data-confirm="Delete this subscription and its event log?"
              >
                Delete
              </button>
            </td>
          </tr>
          <tr :if={@subscriptions == []}>
            <td colspan="5" style="text-align: center; color: #999;">No subscriptions yet.</td>
          </tr>
        </tbody>
      </table>
    </div>

    <div class="card">
      <h3 style="margin-top: 0;">Recent events</h3>
      <form phx-change="filter_events" id="webhook-event-filter" style="margin-bottom: 10px;">
        <select name="events[status]" style={@input_style}>
          <option value="" selected={@event_filters["status"] == ""}>All statuses</option>
          <option :for={s <- @statuses} value={s} selected={@event_filters["status"] == s}>{s}</option>
        </select>
        <select name="events[subscription_id]" style={@input_style}>
          <option value="" selected={@event_filters["subscription_id"] == ""}>All subscriptions</option>
          <option
            :for={s <- @subscriptions}
            value={s.id}
            selected={@event_filters["subscription_id"] == s.id}
          >
            {s.url}
          </option>
        </select>
      </form>
      <table id="webhook-events">
        <thead>
          <tr>
            <th>Time</th>
            <th>Type</th>
            <th>Subscription</th>
            <th>Status</th>
            <th>Attempts</th>
            <th>Last error</th>
            <th :if={@can_edit}></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={e <- @events} id={"webhook-event-#{e.id}"}>
            <td style="white-space: nowrap;"><small>{format_timestamp(e.inserted_at)}</small></td>
            <td><code>{e.type}</code></td>
            <td style="max-width: 240px; word-break: break-all;">
              <small>{Map.get(@subscription_urls, e.subscription_id, e.subscription_id)}</small>
            </td>
            <td><span class={"badge #{status_badge_class(e.status)}"}>{e.status}</span></td>
            <td>{e.attempts}</td>
            <td style="max-width: 280px; word-break: break-all;"><small>{e.last_error}</small></td>
            <td :if={@can_edit}>
              <button
                :if={e.status == "failed"}
                phx-click="redeliver"
                phx-value-id={e.id}
                class="badge"
              >
                Redeliver
              </button>
            </td>
          </tr>
          <tr :if={@events == []}>
            <td colspan="7" style="text-align: center; color: #999;">No events.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
