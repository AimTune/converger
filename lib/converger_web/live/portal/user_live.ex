defmodule ConvergerWeb.Portal.UserLive do
  use ConvergerWeb, :live_view

  alias Converger.Accounts
  alias Converger.Accounts.{TenantUser, TOTP}

  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.current_tenant.id
    can_manage = socket.assigns.tenant_role in ~w(owner admin)

    {:ok,
     assign(socket,
       tenant_users: Accounts.list_tenant_users(tenant_id),
       page_title: "Users",
       min_password_length: Converger.Accounts.PasswordPolicy.min_length(),
       form: to_form(Accounts.change_tenant_user(%TenantUser{})),
       can_manage: can_manage
     )}
  end

  def handle_event("save", %{"tenant_user" => params}, socket) do
    if socket.assigns.can_manage do
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
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to create users.")}
    end
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    if socket.assigns.can_manage do
      user = Accounts.get_tenant_user!(id)

      if user.tenant_id == socket.assigns.current_tenant.id do
        toggle_user_status(socket, user)
      else
        {:noreply, put_flash(socket, :error, "Unauthorized")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if socket.assigns.can_manage do
      user = Accounts.get_tenant_user!(id)

      cond do
        user.tenant_id != socket.assigns.current_tenant.id ->
          {:noreply, put_flash(socket, :error, "Unauthorized")}

        user.id == socket.assigns.current_tenant_user.id ->
          {:noreply, put_flash(socket, :error, "You cannot delete your own account.")}

        true ->
          delete_user(socket, user)
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to delete users.")}
    end
  end

  # Lost authenticator: an owner/admin turns a team member's 2FA off
  # (audit-logged).
  def handle_event("reset_2fa", %{"id" => id}, socket) do
    user = Accounts.get_tenant_user!(id)

    cond do
      not socket.assigns.can_manage ->
        {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}

      user.tenant_id != socket.assigns.current_tenant.id ->
        {:noreply, put_flash(socket, :error, "Unauthorized")}

      true ->
        case TOTP.reset(user, build_actor(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(tenant_users: Accounts.list_tenant_users(socket.assigns.current_tenant.id))
             |> put_flash(:info, "Two-factor authentication reset for #{user.email}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to reset two-factor authentication")}
        end
    end
  end

  defp toggle_user_status(socket, user) do
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

  defp delete_user(socket, user) do
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

  defp build_actor(socket) do
    case socket.assigns[:current_tenant_user] do
      %{email: email} -> %{type: "tenant_user", id: email}
      _ -> %{type: "tenant_user", id: "unknown"}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Users
        <:subtitle>Team members who can sign in to this tenant's portal.</:subtitle>
      </.header>

      <.panel :if={@can_manage} title="Add User">
        <.form for={@form} id="portal-user-form" phx-submit="save">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
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
              options={~w(member viewer admin)}
            />
          </div>
          <.button type="submit" variant="primary">Add User</.button>
        </.form>
      </.panel>

      <div :if={!@can_manage} role="alert" class="alert alert-warning">
        <.icon name="hero-lock-closed" class="size-5" />
        <span>Only owner and admin users can manage team members.</span>
      </div>

      <.panel>
        <div class="overflow-x-auto">
          <.table id="portal-users" rows={@tenant_users} row_id={&"portal-user-#{&1.id}"}>
            <:col :let={user} label="Name"><span class="font-medium">{user.name}</span></:col>
            <:col :let={user} label="Email">{user.email}</:col>
            <:col :let={user} label="Role"><.badge value={user.role} /></:col>
            <:col :let={user} label="Status"><.badge value={user.status} /></:col>
            <:col :let={user} label="2FA">
              <.badge value={if TOTP.enabled?(user), do: "enabled", else: "disabled"}>
                {if TOTP.enabled?(user), do: "on", else: "off"}
              </.badge>
            </:col>
            <:col :let={user} label="Joined">
              <span class="text-xs text-base-content/70">
                {Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M")}
              </span>
            </:col>
            <:action :let={user} :if={@can_manage}>
              <.button phx-click="toggle_status" phx-value-id={user.id} size="xs" variant="neutral">
                {if user.status == "active", do: "Disable", else: "Enable"}
              </.button>
              <.button
                :if={TOTP.enabled?(user) && user.id != @current_tenant_user.id}
                phx-click="reset_2fa"
                phx-value-id={user.id}
                data-confirm="Turn off two-factor authentication for this user?"
                size="xs"
                variant="neutral"
              >
                Reset 2FA
              </.button>
              <.button
                :if={user.id != @current_tenant_user.id}
                phx-click="delete"
                phx-value-id={user.id}
                data-confirm="Are you sure you want to remove this user?"
                size="xs"
                variant="error"
              >
                Delete
              </.button>
              <span :if={user.id == @current_tenant_user.id} class="text-xs text-base-content/60">
                (you)
              </span>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@tenant_users == []}>No users found.</.empty_state>
      </.panel>
    </Layouts.app>
    """
  end
end
