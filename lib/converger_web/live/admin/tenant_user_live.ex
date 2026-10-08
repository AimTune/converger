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
    <h1>Tenant Users</h1>

    <div :if={!@is_viewer} class="card">
      <h3>Create Tenant User</h3>
      <.form for={@form} phx-submit="save">
        <div style="display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap;">
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Tenant</label>
            <select name="tenant_user[tenant_id]" required
              style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;">
              <option value="">Select Tenant...</option>
              <option :for={t <- @tenants} value={t.id}><%= t.name %></option>
            </select>
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Name</label>
            <input type="text" name="tenant_user[name]" placeholder="Full Name" required
              style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;" />
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Email</label>
            <input type="email" name="tenant_user[email]" placeholder="user@example.com" required
              style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;" />
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Password</label>
            <input type="password" name="tenant_user[password]" placeholder="Min 8 characters" required minlength="8"
              style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;" />
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Role</label>
            <select name="tenant_user[role]" style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;">
              <option value="member">member</option>
              <option value="viewer">viewer</option>
              <option value="admin">admin</option>
              <option value="owner">owner</option>
            </select>
          </div>
          <button type="submit">Create</button>
        </div>
      </.form>
    </div>

    <div class="card">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;">
        <h3 style="margin: 0;">Tenant Users</h3>
        <div>
          <label style="font-size: 0.85em; color: #555; margin-right: 5px;">Filter by Tenant:</label>
          <select phx-change="filter" name="tenant_id"
            style="padding: 6px; border: 1px solid #ddd; border-radius: 4px;">
            <option value="">All Tenants</option>
            <option :for={t <- @tenants} value={t.id} selected={t.id == @filter_tenant_id}><%= t.name %></option>
          </select>
        </div>
      </div>
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Email</th>
            <th>Tenant</th>
            <th>Role</th>
            <th>Status</th>
            <th>Created</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody id="tenant-users" phx-update="stream">
          <tr :for={{dom_id, user} <- @streams.tenant_users} id={dom_id}>
            <td><%= user.name %></td>
            <td><%= user.email %></td>
            <td><%= user.tenant.name %></td>
            <td>
              <span class={"badge badge-#{user.role}"}><%= user.role %></span>
            </td>
            <td>
              <span class={"badge badge-#{user.status}"}><%= user.status %></span>
            </td>
            <td><small><%= Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M") %></small></td>
            <td>
              <button :if={!@is_viewer} phx-click="toggle_status" phx-value-id={user.id} class="badge">
                <%= if user.status == "active", do: "Disable", else: "Enable" %>
              </button>
              <button :if={!@is_viewer}
                phx-click="delete" phx-value-id={user.id}
                phx-confirm="Are you sure you want to delete this tenant user?"
                class="badge badge-inactive">
                Delete
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@loaded_count == 0} style="text-align: center; color: #999;">No tenant users found.</p>
      <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 10px;">
        <small style="color: #666;">Showing <%= @loaded_count %> users</small>
        <button :if={@has_more} id="load-more-tenant-users" phx-click="load_more" class="badge">Load more</button>
      </div>
    </div>
    """
  end
end
