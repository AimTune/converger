defmodule ConvergerWeb.Admin.TenantLive do
  @moduledoc """
  Admin Tenants page: create, search (name or exact id), status filter, sort,
  keyset "Load more", and per-tenant actions (enable/disable, tier, API key
  rotation, delete, and an Edit dialog for retention, tier, alert webhook and
  rate-limit overrides). Viewers can browse but not change anything.
  """
  use ConvergerWeb, :live_view

  alias Converger.RateLimit
  alias Converger.Tenants
  alias Converger.Tenants.Tenant

  @filter_keys ~w(q status sort)
  @edit_fields ~w(retention_days tier alert_webhook_url)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:tenants, dom_id: &"tenant-#{&1.id}")
     |> assign(
       page_title: "Tenants",
       form: to_form(Tenants.change_tenant(%Tenant{})),
       revealed_key: nil,
       actor: build_actor(socket),
       can_manage: socket.assigns[:admin_role] in ~w(super_admin admin),
       filters: default_filters(),
       editing: nil,
       edit_form: nil,
       edit_limits: %{},
       limit_errors: [],
       next_cursor: nil,
       has_more: false,
       loaded_count: 0
     )}
  end

  defp default_filters, do: %{"q" => "", "status" => "", "sort" => "desc"}

  def handle_params(params, _url, socket) do
    filters = Map.merge(default_filters(), Map.take(params, @filter_keys))

    {:noreply,
     socket
     |> assign(filters: filters)
     |> load_page(reset: true)}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    query =
      filters
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {k, v} -> v == "" or {k, v} == {"sort", "desc"} end)

    {:noreply, push_patch(socket, to: ~p"/admin/tenants?#{query}")}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more,
      do: {:noreply, load_page(socket, reset: false)},
      else: {:noreply, socket}
  end

  def handle_event("save", %{"tenant" => params}, socket) do
    with :ok <- authorize(socket) do
      case Tenants.create_tenant(params, socket.assigns.actor) do
        {:ok, tenant} ->
          {:noreply,
           socket
           |> put_flash(:info, "Tenant created")
           |> assign(
             form: to_form(Tenants.change_tenant(%Tenant{})),
             revealed_key: reveal(tenant)
           )
           |> load_page(reset: true)}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    end
  end

  def handle_event("rotate_api_key", %{"id" => id}, socket) do
    with :ok <- authorize(socket),
         {:ok, tenant} <- fetch_tenant(socket, id) do
      case Tenants.rotate_api_key(tenant, actor: socket.assigns.actor) do
        {:ok, rotated} ->
          {:noreply,
           socket
           |> put_flash(:info, "API key rotated")
           |> stream_insert(:tenants, rotated)
           |> assign(revealed_key: reveal(rotated))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to rotate API key")}
      end
    end
  end

  def handle_event("dismiss_key", _params, socket) do
    {:noreply, assign(socket, revealed_key: nil)}
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    with :ok <- authorize(socket),
         {:ok, tenant} <- fetch_tenant(socket, id) do
      new_status = if tenant.status == "active", do: "inactive", else: "active"

      case Tenants.update_tenant(tenant, %{status: new_status}, socket.assigns.actor) do
        {:ok, updated} ->
          {:noreply,
           socket |> stream_insert(:tenants, updated) |> put_flash(:info, "Status updated")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update status")}
      end
    end
  end

  def handle_event("cycle_tier", %{"id" => id}, socket) do
    with :ok <- authorize(socket),
         {:ok, tenant} <- fetch_tenant(socket, id) do
      tiers = Tenant.tiers()
      index = Enum.find_index(tiers, &(&1 == tenant.tier)) || 0
      next = Enum.at(tiers, rem(index + 1, length(tiers)))

      case Tenants.update_tenant(tenant, %{tier: next}, socket.assigns.actor) do
        {:ok, updated} ->
          {:noreply,
           socket |> stream_insert(:tenants, updated) |> put_flash(:info, "Tier updated")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update tier")}
      end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with :ok <- authorize(socket),
         {:ok, tenant} <- fetch_tenant(socket, id) do
      case Tenants.delete_tenant(tenant, socket.assigns.actor) do
        {:ok, _} ->
          {:noreply,
           socket
           |> stream_delete(:tenants, tenant)
           |> assign(loaded_count: max(socket.assigns.loaded_count - 1, 0))
           |> put_flash(:info, "Tenant deleted")}

        {:error, _} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to delete tenant (ensure no active channels/conversations)"
           )}
      end
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    with :ok <- authorize(socket),
         {:ok, tenant} <- fetch_tenant(socket, id) do
      {:noreply,
       assign(socket,
         editing: tenant,
         edit_form: to_form(Tenants.change_tenant(tenant), as: :tenant_edit),
         edit_limits: limits_for_form(tenant.limits),
         limit_errors: []
       )}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, close_edit(socket)}
  end

  def handle_event("update", params, socket) do
    with :ok <- authorize(socket),
         %Tenant{id: id} <- socket.assigns.editing,
         {:ok, tenant} <- fetch_tenant(socket, id) do
      attrs = params |> Map.get("tenant_edit", %{}) |> Map.take(@edit_fields)
      raw_limits = Map.get(params, "limits", %{})
      limits = parse_limits(raw_limits)

      changeset = Tenants.change_tenant(tenant, attrs)
      limits_changeset = Tenant.limits_changeset(tenant, limits)

      if changeset.valid? and limits_changeset.valid? do
        save_edit(socket, tenant, changeset, attrs, limits)
      else
        {:noreply,
         assign(socket,
           edit_form: to_form(Map.put(changeset, :action, :validate), as: :tenant_edit),
           edit_limits: limits_for_form(raw_limits),
           limit_errors: error_messages(limits_changeset)
         )}
      end
    else
      nil -> {:noreply, close_edit(socket)}
      other -> other
    end
  end

  defp save_edit(socket, tenant, changeset, attrs, limits) do
    actor = socket.assigns.actor

    result =
      with {:ok, updated} <- maybe_update_tenant(tenant, changeset, attrs, actor) do
        if limits == updated.limits,
          do: {:ok, updated},
          else: Tenants.update_tenant_limits(updated, limits, actor)
      end

    case result do
      {:ok, updated} ->
        {:noreply,
         socket
         |> stream_insert(:tenants, updated)
         |> close_edit()
         |> put_flash(:info, "Tenant updated")}

      {:error, %Ecto.Changeset{} = failed} ->
        {:noreply,
         assign(socket,
           edit_form: to_form(Map.put(failed, :action, :validate), as: :tenant_edit),
           limit_errors: error_messages(failed)
         )}
    end
  end

  defp maybe_update_tenant(tenant, %{changes: changes}, _attrs, _actor) when changes == %{},
    do: {:ok, tenant}

  defp maybe_update_tenant(tenant, _changeset, attrs, actor),
    do: Tenants.update_tenant(tenant, attrs, actor)

  defp close_edit(socket) do
    assign(socket, editing: nil, edit_form: nil, edit_limits: %{}, limit_errors: [])
  end

  # Every bucket the form offers; a bucket with both fields blank is not
  # overridden. Non-numeric input is kept as is so that
  # `Tenant.limits_changeset/2` rejects it with a message.
  defp parse_limits(raw) when is_map(raw) do
    RateLimit.tenant_buckets()
    |> Enum.flat_map(fn bucket ->
      spec = if is_map(raw[bucket]), do: raw[bucket], else: %{}
      limit = Map.get(spec, "limit", "")
      scale = Map.get(spec, "scale_ms", "")

      if blank?(limit) and blank?(scale),
        do: [],
        else: [{bucket, %{"limit" => to_integer(limit), "scale_ms" => to_integer(scale)}}]
    end)
    |> Map.new()
  end

  defp parse_limits(_raw), do: %{}

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> value
    end
  end

  defp to_integer(value), do: value

  defp limits_for_form(limits) when is_map(limits) do
    Map.new(RateLimit.tenant_buckets(), fn bucket ->
      spec = Map.get(limits, bucket) || %{}
      spec = if is_map(spec), do: spec, else: %{}

      {bucket,
       %{
         "limit" => to_string(Map.get(spec, "limit", "")),
         "scale_ms" => to_string(Map.get(spec, "scale_ms", ""))
       }}
    end)
  end

  defp limits_for_form(_limits), do: limits_for_form(%{})

  defp error_messages(%Ecto.Changeset{errors: errors}) do
    for {:limits, error} <- errors, do: translate_error(error)
  end

  defp default_limit(bucket) do
    case Map.get(RateLimit.default_limits(), String.to_existing_atom(bucket)) do
      {limit, scale_ms} -> {to_string(limit), to_string(scale_ms)}
      _ -> {"", ""}
    end
  end

  defp authorize(socket) do
    if socket.assigns.can_manage,
      do: :ok,
      else: {:noreply, put_flash(socket, :error, "Viewers cannot manage tenants.")}
  end

  defp fetch_tenant(socket, id) do
    case Tenants.get_tenant(id) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:noreply, put_flash(socket, :error, "Tenant not found")}
    end
  end

  # Keyset page of tenants; `reset: true` starts over (filter change).
  defp load_page(socket, reset: reset) do
    cursor = if reset, do: nil, else: socket.assigns.next_cursor
    filters = socket.assigns.filters

    page =
      case Tenants.paginate_tenants(Map.take(filters, ~w(q status)),
             cursor: cursor,
             direction: sort_direction(filters)
           ) do
        {:ok, page} -> page
        {:error, :invalid_cursor} -> %Converger.Pagination.Page{}
      end

    loaded = if reset, do: 0, else: socket.assigns.loaded_count

    socket
    |> stream(:tenants, page.entries, reset: reset)
    |> assign(
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      loaded_count: loaded + length(page.entries)
    )
  end

  defp sort_direction(%{"sort" => "asc"}), do: :asc
  defp sort_direction(_), do: :desc

  # The plaintext key only exists on the struct returned right after
  # creation/rotation; it is kept in the socket until dismissed.
  defp reveal(%Tenant{api_key: key} = tenant) when is_binary(key) do
    %{
      tenant_name: tenant.name,
      key: key,
      previous_expires_at: tenant.previous_api_key_expires_at
    }
  end

  defp reveal(_), do: nil

  defp build_actor(socket) do
    case socket.assigns[:current_admin_user] do
      %{email: email} -> %{type: "admin", id: email}
      _ -> %{type: "admin", id: "unknown"}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Tenants
        <:subtitle>Organizations that own channels, conversations and API keys.</:subtitle>
      </.header>

      <.panel :if={@can_manage} title="Create tenant">
        <.form for={@form} id="tenant-form" phx-submit="save">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
            <.input field={@form[:name]} label="Name" placeholder="Tenant name" />
            <div>
              <.input
                field={@form[:alert_webhook_url]}
                label="Alert webhook URL"
                placeholder="https://example.com/alerts (optional)"
              />
              <p class="-mt-1 text-xs text-base-content/60">
                Kept as a managed subscription on channel health events, see Webhooks.
              </p>
            </div>
            <.input field={@form[:tier]} type="select" label="Delivery tier" options={Tenant.tiers()} />
            <.input
              field={@form[:retention_days]}
              type="number"
              label="Retention (days)"
              min={Converger.Retention.min_retention_days()}
            />
          </div>
          <.button type="submit" variant="primary">Create</.button>
        </.form>
      </.panel>

      <div :if={!@can_manage} role="alert" class="alert alert-warning">
        <.icon name="hero-lock-closed" class="size-5" />
        <span>Viewers can browse tenants but not change them.</span>
      </div>

      <div :if={@revealed_key} id="revealed-api-key" role="alert" class="alert alert-warning items-start">
        <.icon name="hero-key" class="size-6 shrink-0" />
        <div class="min-w-0 flex-1 space-y-2">
          <h3 class="font-semibold">API key for {@revealed_key.tenant_name}</h3>
          <p class="text-sm">Copy this key now. It is stored hashed and will not be shown again.</p>
          <code class="block rounded bg-base-100 p-2 font-mono text-sm break-all text-base-content">{@revealed_key.key}</code>
          <p :if={@revealed_key.previous_expires_at} class="text-xs">
            The previous key stays valid until {Calendar.strftime(
              @revealed_key.previous_expires_at,
              "%Y-%m-%d %H:%M UTC"
            )}.
          </p>
          <.button phx-click="dismiss_key" size="sm" variant="neutral">I have saved the key</.button>
        </div>
      </div>

      <.panel>
        <form id="tenant-filter" phx-change="filter" phx-submit="filter">
          <div class="grid gap-x-4 sm:grid-cols-3">
            <.input
              type="search"
              id="tenant-filter-q"
              name="filters[q]"
              value={@filters["q"]}
              label="Search"
              placeholder="Name or tenant id"
              phx-debounce="300"
            />
            <.input
              type="select"
              id="tenant-filter-status"
              name="filters[status]"
              value={@filters["status"]}
              label="Status"
              options={[{"All", ""}, {"active", "active"}, {"inactive", "inactive"}]}
            />
            <.input
              type="select"
              id="tenant-filter-sort"
              name="filters[sort]"
              value={@filters["sort"]}
              label="Sort"
              options={[{"Newest first", "desc"}, {"Oldest first", "asc"}]}
            />
          </div>
        </form>

        <div class="overflow-x-auto">
          <.table id="tenants" rows={@streams.tenants}>
            <:col :let={{_id, tenant}} label="Name">
              <div class="font-medium">{tenant.name}</div>
              <div class="font-mono text-xs text-base-content/60">{tenant.id}</div>
            </:col>
            <:col :let={{_id, tenant}} label="API key">
              <code class="font-mono text-xs">{Tenant.masked_api_key(tenant)}</code>
            </:col>
            <:col :let={{_id, tenant}} label="Alert webhook">
              <span
                :if={tenant.alert_webhook_url && tenant.alert_webhook_url != ""}
                class="block max-w-60 truncate text-xs text-base-content/70"
                title={tenant.alert_webhook_url}
              >
                {tenant.alert_webhook_url}
              </span>
              <span :if={!tenant.alert_webhook_url || tenant.alert_webhook_url == ""} class="text-base-content/40">
                —
              </span>
            </:col>
            <:col :let={{_id, tenant}} label="Retention">{tenant.retention_days} days</:col>
            <:col :let={{_id, tenant}} label="Limits">
              <span :if={tenant.limits in [nil, %{}]} class="text-xs text-base-content/60">
                defaults
              </span>
              <span :if={tenant.limits not in [nil, %{}]} class="text-xs">
                {map_size(tenant.limits)} override(s)
              </span>
            </:col>
            <:col :let={{_id, tenant}} label="Status"><.badge value={tenant.status} /></:col>
            <:col :let={{_id, tenant}} label="Tier">
              <button
                :if={@can_manage}
                type="button"
                phx-click="cycle_tier"
                phx-value-id={tenant.id}
                class={["badge badge-sm cursor-pointer", badge_color(tenant.tier)]}
                title="Delivery queue tier: high → default → bulk (click to change)"
              >
                {tenant.tier}
              </button>
              <.badge :if={!@can_manage} value={tenant.tier} />
            </:col>
            <:action :let={{_id, tenant}} :if={@can_manage}>
              <.button
                id={"edit-tenant-#{tenant.id}"}
                phx-click="edit"
                phx-value-id={tenant.id}
                size="xs"
                variant="neutral"
              >
                Edit
              </.button>
              <.button phx-click="toggle_status" phx-value-id={tenant.id} size="xs" variant="neutral">
                {if tenant.status == "active", do: "Disable", else: "Enable"}
              </.button>
              <.button
                phx-click="rotate_api_key"
                phx-value-id={tenant.id}
                data-confirm="Generate a new API key? The current key stays valid for a grace period."
                size="xs"
                variant="neutral"
              >
                Rotate key
              </.button>
              <.button
                phx-click="delete"
                phx-value-id={tenant.id}
                data-confirm="Are you sure?"
                size="xs"
                variant="error"
              >
                Delete
              </.button>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@loaded_count == 0}>No tenants found.</.empty_state>
        <div class="flex items-center justify-between gap-2">
          <span class="text-sm text-base-content/60">Showing {@loaded_count} tenants</span>
          <.button
            :if={@has_more}
            id="load-more-tenants"
            phx-click="load_more"
            size="sm"
            variant="neutral"
          >
            Load more
          </.button>
        </div>
      </.panel>

      <div
        :if={@editing}
        id="tenant-edit-modal"
        class="modal modal-open"
        role="dialog"
        aria-modal="true"
        aria-labelledby="tenant-edit-title"
        phx-window-keydown="cancel_edit"
        phx-key="escape"
      >
        <div class="modal-box max-w-3xl">
          <h3 id="tenant-edit-title" class="text-lg font-semibold">Edit {@editing.name}</h3>
          <.form for={@edit_form} id="tenant-edit-form" phx-submit="update" class="mt-4">
            <div class="grid gap-x-4 sm:grid-cols-3">
              <.input
                field={@edit_form[:retention_days]}
                type="number"
                label="Retention (days)"
                min={Converger.Retention.min_retention_days()}
              />
              <.input
                field={@edit_form[:tier]}
                type="select"
                label="Delivery tier"
                options={Tenant.tiers()}
              />
              <.input
                field={@edit_form[:alert_webhook_url]}
                label="Alert webhook URL"
                placeholder="https://example.com/alerts (optional)"
              />
            </div>
            <p class="text-xs text-base-content/60">
              Minimum retention is {Converger.Retention.min_retention_days()} days.
            </p>

            <h4 class="mt-4 font-semibold">Rate-limit overrides</h4>
            <p class="text-xs text-base-content/60">
              Leave both fields of a bucket empty to use the default (shown as placeholder).
            </p>
            <div class="mt-2 grid gap-x-4 sm:grid-cols-2">
              <fieldset :for={bucket <- Converger.RateLimit.tenant_buckets()} class="fieldset">
                <legend class="fieldset-legend font-mono text-sm">{bucket}</legend>
                <div class="grid grid-cols-2 gap-x-2">
                  <.input
                    type="number"
                    id={"limits_#{bucket}_limit"}
                    name={"limits[#{bucket}][limit]"}
                    value={@edit_limits[bucket]["limit"]}
                    label="Requests"
                    min="1"
                    placeholder={elem(default_limit(bucket), 0)}
                  />
                  <.input
                    type="number"
                    id={"limits_#{bucket}_scale_ms"}
                    name={"limits[#{bucket}][scale_ms]"}
                    value={@edit_limits[bucket]["scale_ms"]}
                    label="Window (ms)"
                    min="1"
                    placeholder={elem(default_limit(bucket), 1)}
                  />
                </div>
              </fieldset>
            </div>
            <div :if={@limit_errors != []} id="tenant-limit-errors" class="mt-2">
              <.error :for={msg <- @limit_errors}>{msg}</.error>
            </div>

            <div class="modal-action">
              <.button type="button" phx-click="cancel_edit" variant="ghost">Cancel</.button>
              <.button type="submit" variant="primary">Save</.button>
            </div>
          </.form>
        </div>
        <button type="button" class="modal-backdrop" phx-click="cancel_edit" aria-label="Close">
          close
        </button>
      </div>
    </Layouts.app>
    """
  end
end
