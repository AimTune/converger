defmodule ConvergerWeb.Portal.UserLive do
  use ConvergerWeb, :live_view

  alias Converger.Accounts
  alias Converger.Accounts.TenantUser

  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.current_tenant.id
    can_manage = socket.assigns.tenant_role in ~w(owner admin)

    {:ok,
     assign(socket,
       tenant_users: Accounts.list_tenant_users(tenant_id),
       page_title: "Users",
       form: to_form(Accounts.change_tenant_user(%TenantUser{})),
       can_manage: can_manage
     )}
  end

  def handle_event("save", %{"tenant_user" => params}, socket) do
    if not socket.assigns.can_manage do
      {:noreply, put_flash(socket, :error, "You don't have permission to create users.")}
    else
      tenant_id = socket.assigns.current_tenant.id
      params = Map.put(params, "tenant_id", tenant_id)

      case Accounts.create_tenant_user(params, build_actor(socket)) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "User created")
           |> assign(
             tenant_users: Accounts.list_tenant_users(tenant_id),
             form: to_form(Accounts.change_tenant_user(%TenantUser{}))
           )}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    end
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    if not socket.assigns.can_manage do
      {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}
    else
      user = Accounts.get_tenant_user!(id)

      if user.tenant_id != socket.assigns.current_tenant.id do
        {:noreply, put_flash(socket, :error, "Unauthorized")}
      else
        new_status = if user.status == "active", do: "inactive", else: "active"

        case Accounts.update_tenant_user(user, %{status: new_status}, build_actor(socket)) do
          {:ok, _} ->
            {:noreply,
             assign(socket,
               tenant_users: Accounts.list_tenant_users(socket.assigns.current_tenant.id)
             )
             |> put_flash(:info, "Status updated")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update status")}
        end
      end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if not socket.assigns.can_manage do
      {:noreply, put_flash(socket, :error, "You don't have permission to delete users.")}
    else
      user = Accounts.get_tenant_user!(id)

      if user.tenant_id != socket.assigns.current_tenant.id do
        {:noreply, put_flash(socket, :error, "Unauthorized")}
      else
        if user.id == socket.assigns.current_tenant_user.id do
          {:noreply, put_flash(socket, :error, "You cannot delete your own account.")}
        else
          case Accounts.delete_tenant_user(user, build_actor(socket)) do
            {:ok, _} ->
              {:noreply,
               assign(socket,
                 tenant_users: Accounts.list_tenant_users(socket.assigns.current_tenant.id)
               )
               |> put_flash(:info, "User deleted")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to delete user")}
          end
        end
      end
    end
  end

  defp build_actor(socket) do
    case socket.assigns[:current_tenant_user] do
      %{email: email} -> %{type: "tenant_user", id: email}
      _ -> %{type: "tenant_user", id: "unknown"}
    end
  end

  def render(assigns) do
    ~H"""
    <h1>Users</h1>

    <div :if={@can_manage} class="card">
      <h3>Add User</h3>
      <.form for={@form} phx-submit="save">
        <div style="display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap;">
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
            </select>
          </div>
          <button type="submit">Add User</button>
        </div>
      </.form>
    </div>

    <div :if={!@can_manage} class="card" style="background: #fff3e0; color: #e65100;">
      Only owner and admin users can manage team members.
    </div>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Email</th>
            <th>Role</th>
            <th>Status</th>
            <th>Joined</th>
            <th :if={@can_manage}>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={user <- @tenant_users}>
            <td><%= user.name %></td>
            <td><%= user.email %></td>
            <td>
              <span class={"badge badge-#{user.role}"}><%= user.role %></span>
            </td>
            <td>
              <span class={"badge badge-#{user.status}"}><%= user.status %></span>
            </td>
            <td><small><%= Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M") %></small></td>
            <td :if={@can_manage}>
              <button phx-click="toggle_status" phx-value-id={user.id} class="badge">
                <%= if user.status == "active", do: "Disable", else: "Enable" %>
              </button>
              <button :if={user.id != @current_tenant_user.id}
                phx-click="delete" phx-value-id={user.id}
                phx-confirm="Are you sure you want to remove this user?"
                class="badge badge-inactive">
                Delete
              </button>
              <span :if={user.id == @current_tenant_user.id} style="color: #999; font-size: 0.85em;">(you)</span>
            </td>
          </tr>
          <tr :if={@tenant_users == []}>
            <td colspan="6" style="text-align: center; color: #999;">No users found.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
