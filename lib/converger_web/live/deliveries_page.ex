defmodule ConvergerWeb.Live.DeliveriesPage do
  @moduledoc """
  Shared implementation of the admin (`/admin/deliveries`) and portal
  (`/portal/deliveries`) Deliveries pages: dead-letter inspection, payload
  preview (secrets redacted), per-row and bulk retry, and CSV export.

  The two LiveViews only differ in scope, which they pass as `opts`:

    * `:base_path` - `"/admin/deliveries"` or `"/portal/deliveries"`
    * `:tenant_id` - forced tenant scope (portal), or `nil` (admin, all tenants)
    * `:can_retry` - whether the user may replay deliveries
    * `:actor` - audit actor (`%{type: ..., id: ...}`)
    * `:channels` - channels offered in the filter
    * `:tenants` - tenants offered in the filter (admin only), or `nil`

  Keyset pagination on `(updated_at, id)` with "Load more", like the audit log.
  """
  use ConvergerWeb, :html

  import Phoenix.LiveView

  alias Converger.Deliveries

  @filter_keys ~w(tenant_id status channel_id from to)

  def mount(socket, opts) do
    assign(socket,
      page_title: "Deliveries",
      base_path: Keyword.fetch!(opts, :base_path),
      scope_tenant_id: Keyword.get(opts, :tenant_id),
      can_retry: Keyword.fetch!(opts, :can_retry),
      actor: Keyword.fetch!(opts, :actor),
      channels: Keyword.fetch!(opts, :channels),
      tenants: Keyword.get(opts, :tenants),
      params: default_params(),
      filters: %{status: "failed"},
      next_cursor: nil,
      has_more: false,
      loaded_count: 0
    )
  end

  defp default_params, do: @filter_keys |> Map.new(&{&1, ""}) |> Map.put("status", "failed")

  def handle_params(params, socket) do
    params = Map.merge(default_params(), Map.take(params, @filter_keys))

    case filters_for(params, socket) do
      {:ok, filters} ->
        {:noreply,
         socket
         |> assign(params: params, filters: filters)
         |> load_page(reset: true)}

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> assign(params: default_params(), filters: %{status: "failed"})
         |> load_page(reset: true)}
    end
  end

  defp filters_for(params, socket) do
    with {:ok, filters} <- Deliveries.cast_filters(params) do
      case socket.assigns.scope_tenant_id || tenant_param(params["tenant_id"]) do
        nil -> {:ok, filters}
        tenant_id -> {:ok, Map.put(filters, :tenant_id, tenant_id)}
      end
    end
  end

  defp tenant_param(value) do
    case Ecto.UUID.cast(value || "") do
      {:ok, id} -> id
      :error -> nil
    end
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    query = filters |> Map.take(@filter_keys) |> Enum.reject(fn {_k, v} -> v == "" end)
    {:noreply, push_patch(socket, to: "#{socket.assigns.base_path}?#{URI.encode_query(query)}")}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more,
      do: {:noreply, load_page(socket, reset: false)},
      else: {:noreply, socket}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    with true <- socket.assigns.can_retry || :forbidden,
         %{} = delivery <- fetch_delivery(id, socket),
         {:ok, _} <- Deliveries.retry_delivery(delivery, socket.assigns.actor) do
      {:noreply,
       socket
       |> stream_insert(:deliveries, reload(delivery.id))
       |> put_flash(:info, "Delivery re-enqueued")}
    else
      :forbidden ->
        {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}

      nil ->
        {:noreply, put_flash(socket, :error, "Delivery not found")}

      {:error, :not_failed} ->
        {:noreply, put_flash(socket, :error, "Only failed deliveries can be retried")}

      {:error, :channel_inactive} ->
        {:noreply, put_flash(socket, :error, "The channel is inactive")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Retry failed: #{inspect(reason)}")}
    end
  end

  def handle_event("bulk_retry", _params, socket) do
    if socket.assigns.can_retry do
      {:ok, %{retried: count, has_more: more}} =
        Deliveries.retry_dead_letters(socket.assigns.filters, socket.assigns.actor)

      message =
        if more,
          do: "Re-enqueued #{count} deliveries; more remain, run the retry again",
          else: "Re-enqueued #{count} deliveries"

      {:noreply, socket |> put_flash(:info, message) |> load_page(reset: true)}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}
    end
  end

  defp fetch_delivery(id, socket) do
    case {Ecto.UUID.cast(id), socket.assigns.scope_tenant_id} do
      {:error, _} -> nil
      {{:ok, id}, nil} -> Converger.Repo.get(Converger.Deliveries.Delivery, id)
      {{:ok, id}, tenant_id} -> Deliveries.get_tenant_delivery(id, tenant_id)
    end
  end

  defp reload(id) do
    Converger.Deliveries.Delivery
    |> Converger.Repo.get!(id)
    |> Converger.Repo.preload([:channel, :activity])
  end

  defp load_page(socket, reset: reset) do
    cursor = if reset, do: nil, else: socket.assigns.next_cursor

    page =
      case Deliveries.search_deliveries(socket.assigns.filters,
             cursor: cursor,
             preload: [:channel, :activity]
           ) do
        {:ok, page} -> page
        {:error, :invalid_cursor} -> %Converger.Pagination.Page{}
      end

    loaded = if reset, do: 0, else: socket.assigns.loaded_count

    socket
    |> stream(:deliveries, page.entries, reset: reset)
    |> assign(
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      loaded_count: loaded + length(page.entries)
    )
  end

  defp export_path(base_path, params) do
    query = params |> Enum.reject(fn {_k, v} -> v == "" end) |> URI.encode_query()
    "#{base_path}/export?#{query}"
  end

  defp status_badge_class("failed"), do: "badge-inactive"
  defp status_badge_class(status) when status in ~w(sent delivered read), do: "badge-active"
  defp status_badge_class(_), do: ""

  defp format_timestamp(nil), do: "-"
  defp format_timestamp(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp truncate_id(id) when is_binary(id), do: String.slice(id, 0..7) <> "..."
  defp truncate_id(_), do: "-"

  @label_style "display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;"
  @input_style "padding: 6px; border: 1px solid #ddd; border-radius: 4px;"

  def render(assigns) do
    assigns = assign(assigns, label_style: @label_style, input_style: @input_style)

    ~H"""
    <h1>Deliveries</h1>

    <div class="card" style="margin-bottom: 20px;">
      <form phx-change="filter" id="delivery-filter-form">
        <div style="display: flex; gap: 15px; align-items: flex-end; flex-wrap: wrap;">
          <div :if={@tenants}>
            <label style={@label_style}>Tenant</label>
            <select name="filters[tenant_id]" style={@input_style}>
              <option value="">All Tenants</option>
              <option :for={t <- @tenants} value={t.id} selected={@params["tenant_id"] == t.id}>
                {t.name}
              </option>
            </select>
          </div>

          <div>
            <label style={@label_style}>Channel</label>
            <select name="filters[channel_id]" style={@input_style}>
              <option value="">All Channels</option>
              <option :for={c <- @channels} value={c.id} selected={@params["channel_id"] == c.id}>
                {c.name}
              </option>
            </select>
          </div>

          <div>
            <label style={@label_style}>Status</label>
            <select name="filters[status]" style={@input_style}>
              <option value="" selected={@params["status"] == ""}>All</option>
              <option
                :for={s <- Converger.Deliveries.Delivery.statuses()}
                value={s}
                selected={@params["status"] == s}
              >
                {s}
              </option>
            </select>
          </div>

          <div>
            <label style={@label_style}>From</label>
            <input type="date" name="filters[from]" value={@params["from"]} style={@input_style} />
          </div>

          <div>
            <label style={@label_style}>To</label>
            <input type="date" name="filters[to]" value={@params["to"]} style={@input_style} />
          </div>

          <a
            href={@base_path}
            style="padding: 6px 12px; background: #6c757d; color: white; border-radius: 4px; text-decoration: none; font-size: 0.9em;"
          >
            Reset
          </a>
          <a
            id="export-deliveries"
            href={export_path(@base_path, @params)}
            style="padding: 6px 12px; background: #17a2b8; color: white; border-radius: 4px; text-decoration: none; font-size: 0.9em;"
          >
            Export CSV
          </a>
          <button
            :if={@can_retry}
            type="button"
            id="bulk-retry"
            phx-click="bulk_retry"
            data-confirm="Re-enqueue every failed delivery matching these filters?"
            style="font-size: 0.9em;"
          >
            Retry all failed
          </button>
        </div>
      </form>
    </div>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>Last change</th>
            <th>Channel</th>
            <th>Activity</th>
            <th>Status</th>
            <th>Attempts</th>
            <th>Retries</th>
            <th>Error / payload</th>
            <th :if={@can_retry}>Actions</th>
          </tr>
        </thead>
        <tbody id="deliveries" phx-update="stream">
          <tr :for={{dom_id, delivery} <- @streams.deliveries} id={dom_id}>
            <td style="white-space: nowrap;"><small>{format_timestamp(delivery.updated_at)}</small></td>
            <td>{delivery.channel && delivery.channel.name}</td>
            <td><small>{truncate_id(delivery.activity_id)}</small></td>
            <td><span class={"badge #{status_badge_class(delivery.status)}"}>{delivery.status}</span></td>
            <td>{delivery.attempts}</td>
            <td>
              {delivery.retry_count}
              <small :if={delivery.retried_by} style="display: block; color: #666;">
                {delivery.retried_by} at {format_timestamp(delivery.retried_at)}
              </small>
            </td>
            <td style="max-width: 420px;">
              <small :if={delivery.last_error} style="color: #721c24; word-break: break-word;">
                {delivery.last_error}
              </small>
              <details>
                <summary style="cursor: pointer; font-size: 0.85em; color: #007bff;">Payload</summary>
                <pre style="font-size: 0.75em; max-height: 240px; overflow: auto; background: #f8f9fa; padding: 8px; border-radius: 4px; margin-top: 5px;">{Jason.encode!(Deliveries.payload_preview(delivery), pretty: true)}</pre>
              </details>
            </td>
            <td :if={@can_retry}>
              <button
                :if={delivery.status == "failed"}
                id={"retry-#{delivery.id}"}
                phx-click="retry"
                phx-value-id={delivery.id}
                class="badge"
              >
                Retry
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@loaded_count == 0} style="text-align: center; color: #999; padding: 30px;">
        No deliveries found
      </p>
      <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 10px;">
        <span style="color: #666; font-size: 0.9em;">Showing {@loaded_count} deliveries</span>
        <button :if={@has_more} id="load-more-deliveries" phx-click="load_more" style="font-size: 0.85em;">
          Load more
        </button>
      </div>
    </div>
    """
  end
end
