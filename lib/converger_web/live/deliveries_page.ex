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

  defp format_timestamp(nil), do: "-"
  defp format_timestamp(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp truncate_id(id) when is_binary(id), do: String.slice(id, 0..7) <> "..."
  defp truncate_id(_), do: "-"

  defp tenant_options(tenants), do: [{"All Tenants", ""} | Enum.map(tenants, &{&1.name, &1.id})]

  defp channel_options(channels),
    do: [{"All Channels", ""} | Enum.map(channels, &{&1.name, &1.id})]

  defp status_options,
    do: [{"All", ""} | Enum.map(Converger.Deliveries.Delivery.statuses(), &{&1, &1})]

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Deliveries
        <:subtitle>Dead-letter inspection, payload preview, retry and CSV export.</:subtitle>
      </.header>

      <.panel title="Filters">
        <form phx-change="filter" id="delivery-filter-form">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-5">
            <.input
              :if={@tenants}
              type="select"
              id="delivery-filter-tenant"
              name="filters[tenant_id]"
              label="Tenant"
              value={@params["tenant_id"]}
              options={tenant_options(@tenants)}
            />
            <.input
              type="select"
              id="delivery-filter-channel"
              name="filters[channel_id]"
              label="Channel"
              value={@params["channel_id"]}
              options={channel_options(@channels)}
            />
            <.input
              type="select"
              id="delivery-filter-status"
              name="filters[status]"
              label="Status"
              value={@params["status"]}
              options={status_options()}
            />
            <.input
              type="date"
              id="delivery-filter-from"
              name="filters[from]"
              label="From"
              value={@params["from"]}
            />
            <.input
              type="date"
              id="delivery-filter-to"
              name="filters[to]"
              label="To"
              value={@params["to"]}
            />
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.button href={@base_path} size="sm" variant="ghost">
              <.icon name="hero-x-mark" class="size-4" /> Reset
            </.button>
            <.button
              id="export-deliveries"
              href={export_path(@base_path, @params)}
              size="sm"
              variant="neutral"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Export CSV
            </.button>
            <.button
              :if={@can_retry}
              type="button"
              id="bulk-retry"
              phx-click="bulk_retry"
              data-confirm="Re-enqueue every failed delivery matching these filters?"
              size="sm"
              variant="error"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Retry all failed
            </.button>
          </div>
        </form>
      </.panel>

      <.panel>
        <div class="overflow-x-auto">
          <.table id="deliveries" rows={@streams.deliveries}>
            <:col :let={{_id, delivery}} label="Last change">
              <span class="whitespace-nowrap text-xs">{format_timestamp(delivery.updated_at)}</span>
            </:col>
            <:col :let={{_id, delivery}} label="Channel">
              {delivery.channel && delivery.channel.name}
            </:col>
            <:col :let={{_id, delivery}} label="Activity">
              <span class="font-mono text-xs">{truncate_id(delivery.activity_id)}</span>
            </:col>
            <:col :let={{_id, delivery}} label="Status"><.badge value={delivery.status} /></:col>
            <:col :let={{_id, delivery}} label="Attempts">{delivery.attempts}</:col>
            <:col :let={{_id, delivery}} label="Retries">
              {delivery.retry_count}
              <span :if={delivery.retried_by} class="block text-xs text-base-content/60">
                {delivery.retried_by} at {format_timestamp(delivery.retried_at)}
              </span>
            </:col>
            <:col :let={{_id, delivery}} label="Error / payload">
              <div class="max-w-md">
                <p :if={delivery.last_error} class="text-xs text-error break-words">
                  {delivery.last_error}
                </p>
                <details>
                  <summary class="cursor-pointer text-xs link link-primary">Payload</summary>
                  <pre class="mt-1 bg-base-200 rounded-box p-3 text-xs overflow-auto max-h-60">{Jason.encode!(Deliveries.payload_preview(delivery), pretty: true)}</pre>
                </details>
              </div>
            </:col>
            <:action :let={{_id, delivery}} :if={@can_retry}>
              <.button
                :if={delivery.status == "failed"}
                id={"retry-#{delivery.id}"}
                phx-click="retry"
                phx-value-id={delivery.id}
                size="xs"
                variant="neutral"
              >
                Retry
              </.button>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@loaded_count == 0}>No deliveries found</.empty_state>
        <div class="flex items-center justify-between gap-2">
          <span class="text-sm text-base-content/60">Showing {@loaded_count} deliveries</span>
          <.button
            :if={@has_more}
            id="load-more-deliveries"
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
