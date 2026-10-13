defmodule ConvergerWeb.Admin.TenantUserLive do
  use ConvergerWeb, :live_view

  alias Converger.Accounts
  alias Converger.Accounts.TenantUser
  alias Converger.Tenants

  def mount(_params, _session, socket) do
    tenants = Tenants.list_tenants()

    is_viewer =
      socket.assigns[:current_admin_user] && socket.assigns.current_admin_user.role == "viewer"

    {:ok,
     socket
     |> assign(
       tenants: tenants,
       page_title: "Tenant Users",
       min_password_length: Converger.Accounts.PasswordPolicy.min_length(),
       form: to_form(Accounts.change_tenant_user(%TenantUser{})),
       filter_tenant_id: "",
       is_viewer: is_viewer,
       next_cursor: nil,
       has_more: false,
       loaded_count: 0
     )
     |> load_users(reset: true)}
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

  def handle_event("filter", %{"tenant_id" => tenant_id}, socket) do
    {:noreply,
     socket
     |> assign(filter_tenant_id: tenant_id)
     |> load_users(reset: true)}
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
        {:ok, _} ->
          {:noreply,
           socket
           |> stream_insert(:tenant_users, Accounts.get_tenant_user!(id))
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

  # Keyset page of tenant users (newest first); `reset: true` starts over.
  defp load_users(socket, reset: reset) do
    cursor = if reset, do: nil, else: socket.assigns.next_cursor
    filters = %{"tenant_id" => socket.assigns.filter_tenant_id}

    page =
      case Accounts.paginate_tenant_users(filters, cursor: cursor) do
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
        <:actions>
          <form id="tenant-user-filter" phx-change="filter" class="w-56">
            <.input
              id="tenant_user_filter_tenant_id"
              type="select"
              name="tenant_id"
              value={@filter_tenant_id}
              label="Filter by Tenant"
              prompt="All Tenants"
              options={Enum.map(@tenants, &{&1.name, &1.id})}
              class="select select-sm w-full"
            />
          </form>
        </:actions>
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
