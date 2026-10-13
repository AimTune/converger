defmodule ConvergerWeb.Admin.AdminUserLive do
  @moduledoc """
  Admin Users page: search (name/email), role and status filters, sort and
  keyset "Load more". Only a super_admin creates and manages admin users.
  """
  use ConvergerWeb, :live_view

  alias Converger.Accounts
  alias Converger.Accounts.{AdminUser, TOTP}

  @filter_keys ~w(q role status sort)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:admin_users, dom_id: &"admin-user-#{&1.id}")
     |> assign(
       page_title: "Admin Users",
       min_password_length: Converger.Accounts.PasswordPolicy.min_length(),
       form: to_form(Accounts.change_admin_user(%AdminUser{})),
       show_form: can_manage_users?(socket),
       filters: default_filters(),
       next_cursor: nil,
       has_more: false,
       loaded_count: 0
     )}
  end

  defp default_filters, do: %{"q" => "", "role" => "", "status" => "", "sort" => "desc"}

  def handle_params(params, _url, socket) do
    filters = Map.merge(default_filters(), Map.take(params, @filter_keys))
    {:noreply, socket |> assign(filters: filters) |> load_page(reset: true)}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    query =
      filters
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {k, v} -> v == "" or {k, v} == {"sort", "desc"} end)

    {:noreply, push_patch(socket, to: ~p"/admin/users?#{query}")}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more,
      do: {:noreply, load_page(socket, reset: false)},
      else: {:noreply, socket}
  end

  def handle_event("save", %{"admin_user" => params}, socket) do
    if can_manage_users?(socket) do
      case Accounts.create_admin_user(params, build_actor(socket)) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Admin user created")
           |> assign(form: to_form(Accounts.change_admin_user(%AdminUser{})))
           |> load_page(reset: true)}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Only super_admin can create admin users.")}
    end
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    if can_manage_users?(socket) do
      user = Accounts.get_admin_user!(id)
      new_status = if user.status == "active", do: "inactive", else: "active"

      case Accounts.update_admin_user(user, %{status: new_status}, build_actor(socket)) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> stream_insert(:admin_users, updated)
           |> put_flash(:info, "Status updated")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update status")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only super_admin can manage admin users.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if can_manage_users?(socket) do
      user = Accounts.get_admin_user!(id)

      # Prevent deleting yourself
      if user.id == socket.assigns.current_admin_user.id do
        {:noreply, put_flash(socket, :error, "You cannot delete your own account.")}
      else
        delete_admin_user(socket, user)
      end
    else
      {:noreply, put_flash(socket, :error, "Only super_admin can delete admin users.")}
    end
  end

  # Lost authenticator: a super_admin turns another admin's 2FA off
  # (audit-logged). An admin whose role requires 2FA enrolls again at their
  # next request.
  def handle_event("reset_2fa", %{"id" => id}, socket) do
    if can_manage_users?(socket) do
      user = Accounts.get_admin_user!(id)

      case TOTP.reset(user, build_actor(socket)) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> stream_insert(:admin_users, updated)
           |> put_flash(:info, "Two-factor authentication reset for #{user.email}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to reset two-factor authentication")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only super_admin can reset 2FA.")}
    end
  end

  def handle_event("revoke_sessions", %{"id" => id}, socket) do
    if can_manage_users?(socket) do
      user = Accounts.get_admin_user!(id)
      count = Accounts.revoke_sessions(user, build_actor(socket))
      {:noreply, put_flash(socket, :info, "Signed #{user.email} out of #{count} session(s)")}
    else
      {:noreply, put_flash(socket, :error, "Only super_admin can sign out admin users.")}
    end
  end

  defp delete_admin_user(socket, user) do
    case Accounts.delete_admin_user(user, build_actor(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> stream_delete(:admin_users, user)
         |> assign(loaded_count: max(socket.assigns.loaded_count - 1, 0))
         |> put_flash(:info, "Admin user deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete admin user")}
    end
  end

  # Keyset page of admin users; `reset: true` starts over (filter change).
  defp load_page(socket, reset: reset) do
    cursor = if reset, do: nil, else: socket.assigns.next_cursor
    filters = socket.assigns.filters

    page =
      case Accounts.paginate_admin_users(Map.take(filters, ~w(q role status)),
             cursor: cursor,
             direction: sort_direction(filters)
           ) do
        {:ok, page} -> page
        {:error, :invalid_cursor} -> %Converger.Pagination.Page{}
      end

    loaded = if reset, do: 0, else: socket.assigns.loaded_count

    socket
    |> stream(:admin_users, page.entries, reset: reset)
    |> assign(
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      loaded_count: loaded + length(page.entries)
    )
  end

  defp sort_direction(%{"sort" => "asc"}), do: :asc
  defp sort_direction(_), do: :desc

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
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Admin Users
        <:subtitle>Operators who can sign in to the admin panel.</:subtitle>
      </.header>

      <.panel :if={@show_form} title="Create Admin User">
        <.form for={@form} id="admin-user-form" phx-submit="save">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
            <.input
              id="admin_user_name"
              name="admin_user[name]"
              value=""
              label="Name"
              placeholder="Full Name"
              required
            />
            <.input
              id="admin_user_email"
              type="email"
              name="admin_user[email]"
              value=""
              label="Email"
              placeholder="admin@example.com"
              required
            />
            <.input
              id="admin_user_password"
              type="password"
              name="admin_user[password]"
              value=""
              label="Password"
              placeholder={"Min #{@min_password_length} characters"}
              autocomplete="new-password"
              required
              minlength={@min_password_length}
            />
            <.input
              id="admin_user_role"
              type="select"
              name="admin_user[role]"
              value="admin"
              label="Role"
              options={~w(admin viewer super_admin)}
            />
          </div>
          <.button type="submit" variant="primary">Create</.button>
        </.form>
      </.panel>

      <div :if={!@show_form} role="alert" class="alert alert-warning">
        <.icon name="hero-lock-closed" class="size-5" />
        <span>Only super_admin users can create or manage admin users.</span>
      </div>

      <.panel>
        <form id="admin-user-filter" phx-change="filter" phx-submit="filter">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
            <.input
              type="search"
              id="admin-user-filter-q"
              name="filters[q]"
              value={@filters["q"]}
              label="Search"
              placeholder="Name or email"
              phx-debounce="300"
            />
            <.input
              type="select"
              id="admin-user-filter-role"
              name="filters[role]"
              value={@filters["role"]}
              label="Role"
              options={[{"All", ""} | ~w(super_admin admin viewer)]}
            />
            <.input
              type="select"
              id="admin-user-filter-status"
              name="filters[status]"
              value={@filters["status"]}
              label="Status"
              options={[{"All", ""} | ~w(active inactive)]}
            />
            <.input
              type="select"
              id="admin-user-filter-sort"
              name="filters[sort]"
              value={@filters["sort"]}
              label="Sort"
              options={[{"Newest first", "desc"}, {"Oldest first", "asc"}]}
            />
          </div>
        </form>

        <div class="overflow-x-auto">
          <.table id="admin-users" rows={@streams.admin_users}>
            <:col :let={{_id, user}} label="Name"><span class="font-medium">{user.name}</span></:col>
            <:col :let={{_id, user}} label="Email">{user.email}</:col>
            <:col :let={{_id, user}} label="Role"><.badge value={user.role} /></:col>
            <:col :let={{_id, user}} label="Status"><.badge value={user.status} /></:col>
            <:col :let={{_id, user}} label="2FA">
              <.badge value={if TOTP.enabled?(user), do: "enabled", else: "disabled"}>
                {if TOTP.enabled?(user), do: "on", else: "off"}
              </.badge>
            </:col>
            <:col :let={{_id, user}} label="Created">
              <span class="text-xs text-base-content/70">
                {Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M")}
              </span>
            </:col>
            <:action :let={{_id, user}}>
              <.button
                :if={@show_form}
                phx-click="toggle_status"
                phx-value-id={user.id}
                size="xs"
                variant="neutral"
              >
                {if user.status == "active", do: "Disable", else: "Enable"}
              </.button>
              <.button
                :if={@show_form && TOTP.enabled?(user) && user.id != @current_admin_user.id}
                phx-click="reset_2fa"
                phx-value-id={user.id}
                data-confirm="Turn off two-factor authentication for this admin? They can log in with the password only until they set it up again."
                size="xs"
                variant="neutral"
              >
                Reset 2FA
              </.button>
              <.button
                :if={@show_form && user.id != @current_admin_user.id}
                phx-click="revoke_sessions"
                phx-value-id={user.id}
                data-confirm="Sign this admin out of every session?"
                size="xs"
                variant="neutral"
              >
                Sign out
              </.button>
              <.button
                :if={@show_form && user.id != @current_admin_user.id}
                phx-click="delete"
                phx-value-id={user.id}
                data-confirm="Are you sure you want to delete this admin user?"
                size="xs"
                variant="error"
              >
                Delete
              </.button>
              <span :if={user.id == @current_admin_user.id} class="text-xs text-base-content/60">
                (you)
              </span>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@loaded_count == 0}>No admin users found.</.empty_state>
        <div class="flex items-center justify-between gap-2">
          <span class="text-sm text-base-content/60">Showing {@loaded_count} admin users</span>
          <.button
            :if={@has_more}
            id="load-more-admin-users"
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
