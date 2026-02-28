defmodule ConvergerWeb.Admin.AdminUserLive do
  use ConvergerWeb, :live_view

  alias Converger.Accounts
  alias Converger.Accounts.AdminUser

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       admin_users: Accounts.list_admin_users(),
       page_title: "Admin Users",
       form: to_form(Accounts.change_admin_user(%AdminUser{})),
       show_form: can_manage_users?(socket)
     )}
  end

  def handle_event("save", %{"admin_user" => params}, socket) do
    if not can_manage_users?(socket) do
      {:noreply, put_flash(socket, :error, "Only super_admin can create admin users.")}
    else
      case Accounts.create_admin_user(params, build_actor(socket)) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Admin user created")
           |> assign(
             admin_users: Accounts.list_admin_users(),
             form: to_form(Accounts.change_admin_user(%AdminUser{}))
           )}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    end
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    if not can_manage_users?(socket) do
      {:noreply, put_flash(socket, :error, "Only super_admin can manage admin users.")}
    else
      user = Accounts.get_admin_user!(id)
      new_status = if user.status == "active", do: "inactive", else: "active"

      case Accounts.update_admin_user(user, %{status: new_status}, build_actor(socket)) do
        {:ok, _} ->
          {:noreply,
           assign(socket, admin_users: Accounts.list_admin_users())
           |> put_flash(:info, "Status updated")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update status")}
      end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if not can_manage_users?(socket) do
      {:noreply, put_flash(socket, :error, "Only super_admin can delete admin users.")}
    else
      user = Accounts.get_admin_user!(id)

      # Prevent deleting yourself
      if user.id == socket.assigns.current_admin_user.id do
        {:noreply, put_flash(socket, :error, "You cannot delete your own account.")}
      else
        case Accounts.delete_admin_user(user, build_actor(socket)) do
          {:ok, _} ->
            {:noreply,
             assign(socket, admin_users: Accounts.list_admin_users())
             |> put_flash(:info, "Admin user deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete admin user")}
        end
      end
    end
  end

  defp can_manage_users?(socket) do
    socket.assigns[:current_admin_user] && socket.assigns.current_admin_user.role == "super_admin"
  end

  defp build_actor(socket) do
    case socket.assigns[:current_admin_user] do
      %{email: email} -> %{type: "admin", id: email}
      _ -> %{type: "admin", id: "unknown"}
    end
  end

  def render(assigns) do
    ~H"""
    <h1>Admin Users</h1>

    <div :if={@show_form} class="card">
      <h3>Create Admin User</h3>
      <.form for={@form} phx-submit="save">
        <div style="display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap;">
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Name</label>
            <input type="text" name="admin_user[name]" placeholder="Full Name" required
              style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;" />
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Email</label>
            <input type="email" name="admin_user[email]" placeholder="admin@example.com" required
              style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;" />
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Password</label>
            <input type="password" name="admin_user[password]" placeholder="Min 8 characters" required minlength="8"
              style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;" />
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Role</label>
            <select name="admin_user[role]" style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;">
              <option value="admin">admin</option>
              <option value="viewer">viewer</option>
              <option value="super_admin">super_admin</option>
            </select>
          </div>
          <button type="submit">Create</button>
        </div>
      </.form>
    </div>

    <div :if={!@show_form} class="card" style="background: #fff3e0; color: #e65100;">
      Only super_admin users can create or manage admin users.
    </div>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Email</th>
            <th>Role</th>
            <th>Status</th>
            <th>Created</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={user <- @admin_users}>
            <td><%= user.name %></td>
            <td><%= user.email %></td>
            <td>
              <span class={"badge badge-#{user.role}"}><%= user.role %></span>
            </td>
            <td>
              <span class={"badge badge-#{user.status}"}><%= user.status %></span>
            </td>
            <td><small><%= Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M") %></small></td>
            <td>
              <button :if={@show_form} phx-click="toggle_status" phx-value-id={user.id} class="badge">
                <%= if user.status == "active", do: "Disable", else: "Enable" %>
              </button>
              <button :if={@show_form && user.id != @current_admin_user.id}
                phx-click="delete" phx-value-id={user.id}
                phx-confirm="Are you sure you want to delete this admin user?"
                class="badge badge-inactive">
                Delete
              </button>
              <span :if={user.id == @current_admin_user.id} style="color: #999; font-size: 0.85em;">(you)</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
