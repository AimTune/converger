defmodule ConvergerWeb.Admin.TenantUserLive do
  @moduledoc """
  Admin Tenant Users page: users of every tenant, filtered by tenant, role,
  status and a name/email search, sorted and keyset-paginated ("Load more").
  Viewers can browse but not change anything.
  """
  use ConvergerWeb, :live_view

  alias Converger.Accounts
  alias Converger.Accounts.TenantUser
  alias Converger.Tenants

  @filter_keys ~w(tenant_id q role status sort)

  def mount(_params, _session, socket) do
    tenants = Tenants.list_tenants()

    is_viewer =
      socket.assigns[:current_admin_user] && socket.assigns.current_admin_user.role == "viewer"

    {:ok,
     assign(socket,
       tenants: tenants,
       page_title: "Tenant Users",
       min_password_length: Converger.Accounts.PasswordPolicy.min_length(),
       form: to_form(Accounts.change_tenant_user(%TenantUser{})),
       filters: default_filters(),
       is_viewer: is_viewer,
       next_cursor: nil,
       has_more: false,
       loaded_count: 0
     )}
  end

  defp default_filters do
    %{"tenant_id" => "", "q" => "", "role" => "", "status" => "", "sort" => "desc"}
  end

  def handle_params(params, _url, socket) do
    filters = Map.merge(default_filters(), Map.take(params, @filter_keys))
    {:noreply, socket |> assign(filters: filters) |> load_users(reset: true)}
  end

  def handle_event("save", %{"tenant_user" => params}, socket) do
    if socket.assigns.is_viewer do
      {:noreply, put_flash(socket, :error, "Viewers cannot create users.")}
    else
      case Accounts.create_tenant_user(params, build_actor(socket)) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Tenant user created")
           |> assign(form: to_form(Accounts.change_tenant_user(%TenantUser{})))
           |> load_users(reset: true)}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    end
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    query =
      filters
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {k, v} -> v == "" or {k, v} == {"sort", "desc"} end)

    {:noreply, push_patch(socket, to: ~p"/admin/tenant_users?#{query}")}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply, load_users(socket, reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    if socket.assigns.is_viewer do
      {:noreply, put_flash(socket, :error, "Viewers cannot manage users.")}
    else
      user = Accounts.get_tenant_user!(id)
      new_status = if user.status == "active", do: "inactive", else: "active"

      case Accounts.update_tenant_user(user, %{status: new_status}, build_actor(socket)) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> stream_insert(:tenant_users, updated)
           |> put_flash(:info, "Status updated")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update status")}
      end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if socket.assigns.is_viewer do
      {:noreply, put_flash(socket, :error, "Viewers cannot delete users.")}
    else
      user = Accounts.get_tenant_user!(id)

      case Accounts.delete_tenant_user(user, build_actor(socket)) do
        {:ok, _} ->
          {:noreply,
           socket
           |> stream_delete(:tenant_users, user)
           |> assign(loaded_count: max(socket.assigns.loaded_count - 1, 0))
           |> put_flash(:info, "Tenant user deleted")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete tenant user")}
      end
    end
  end

  # Keyset page of tenant users; `reset: true` starts over (filter change).
  defp load_users(socket, reset: reset) do
    cursor = if reset, do: nil, else: socket.assigns.next_cursor
    filters = socket.assigns.filters

    page =
      case Accounts.paginate_tenant_users(Map.take(filters, ~w(tenant_id q role status)),
             cursor: cursor,
             direction: sort_direction(filters)
           ) do
        {:ok, page} -> page
        {:error, :invalid_cursor} -> %Converger.Pagination.Page{}
      end

    loaded = if reset, do: 0, else: socket.assigns.loaded_count

    socket
    |> stream(:tenant_users, page.entries, reset: reset)
    |> assign(
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      loaded_count: loaded + length(page.entries)
    )
  end

  defp sort_direction(%{"sort" => "asc"}), do: :asc
  defp sort_direction(_), do: :desc

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
        Tenant Users
        <:subtitle>Users who sign in to a tenant's portal.</:subtitle>
      </.header>

      <.panel :if={!@is_viewer} title="Create Tenant User">
        <.form for={@form} id="tenant-user-form" phx-submit="save">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-5">
            <.input
              id="tenant_user_tenant_id"
              type="select"
              name="tenant_user[tenant_id]"
              value=""
              label="Tenant"
              prompt="Select Tenant..."
              options={Enum.map(@tenants, &{&1.name, &1.id})}
              required
            />
            <.input
              id="tenant_user_name"
              name="tenant_user[name]"
              value=""
              label="Name"
              placeholder="Full Name"
              required
            />
            <.input
              id="tenant_user_email"
              type="email"
              name="tenant_user[email]"
              value=""
              label="Email"
              placeholder="user@example.com"
              required
            />
            <.input
              id="tenant_user_password"
              type="password"
              name="tenant_user[password]"
              value=""
              label="Password"
              placeholder={"Min #{@min_password_length} characters"}
              autocomplete="new-password"
              required
              minlength={@min_password_length}
            />
            <.input
              id="tenant_user_role"
              type="select"
              name="tenant_user[role]"
              value="member"
              label="Role"
              options={~w(member viewer admin owner)}
            />
          </div>
          <.button type="submit" variant="primary">Create</.button>
        </.form>
      </.panel>

      <.panel title="Tenant Users">
        <form id="tenant-user-filter" phx-change="filter" phx-submit="filter">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-5">
            <.input
              type="search"
              id="tenant_user_filter_q"
              name="filters[q]"
              value={@filters["q"]}
              label="Search"
              placeholder="Name or email"
              phx-debounce="300"
            />
            <.input
              id="tenant_user_filter_tenant_id"
              type="select"
              name="filters[tenant_id]"
              value={@filters["tenant_id"]}
              label="Tenant"
              prompt="All Tenants"
              options={Enum.map(@tenants, &{&1.name, &1.id})}
            />
            <.input
              id="tenant_user_filter_role"
              type="select"
              name="filters[role]"
              value={@filters["role"]}
              label="Role"
              options={[{"All", ""} | ~w(owner admin member viewer)]}
            />
            <.input
              id="tenant_user_filter_status"
              type="select"
              name="filters[status]"
              value={@filters["status"]}
              label="Status"
              options={[{"All", ""} | ~w(active inactive)]}
            />
            <.input
              id="tenant_user_filter_sort"
              type="select"
              name="filters[sort]"
              value={@filters["sort"]}
              label="Sort"
              options={[{"Newest first", "desc"}, {"Oldest first", "asc"}]}
            />
          </div>
        </form>
        <div class="overflow-x-auto">
          <.table id="tenant-users" rows={@streams.tenant_users}>
            <:col :let={{_id, user}} label="Name"><span class="font-medium">{user.name}</span></:col>
            <:col :let={{_id, user}} label="Email">{user.email}</:col>
            <:col :let={{_id, user}} label="Tenant">{user.tenant.name}</:col>
            <:col :let={{_id, user}} label="Role"><.badge value={user.role} /></:col>
            <:col :let={{_id, user}} label="Status"><.badge value={user.status} /></:col>
            <:col :let={{_id, user}} label="Created">
              <span class="text-xs text-base-content/70">
                {Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M")}
              </span>
            </:col>
            <:action :let={{_id, user}}>
              <.button
                :if={!@is_viewer}
                phx-click="toggle_status"
                phx-value-id={user.id}
                size="xs"
                variant="neutral"
              >
                {if user.status == "active", do: "Disable", else: "Enable"}
              </.button>
              <.button
                :if={!@is_viewer}
                phx-click="delete"
                phx-value-id={user.id}
                data-confirm="Are you sure you want to delete this tenant user?"
                size="xs"
                variant="error"
              >
                Delete
              </.button>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@loaded_count == 0}>No tenant users found.</.empty_state>
        <div class="mt-3 flex items-center justify-between">
          <span class="text-xs text-base-content/60">Showing {@loaded_count} users</span>
          <.button
            :if={@has_more}
            id="load-more-tenant-users"
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
