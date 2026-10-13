defmodule ConvergerWeb.Portal.UserLive do
  @moduledoc """
  Portal Users page: the current tenant's team members, with a name/email
  search, role and status filters, sort and keyset "Load more". Only owners
  and admins manage users; every event re-checks the tenant scope.
  """
  use ConvergerWeb, :live_view

  alias Converger.Accounts
  alias Converger.Accounts.{TenantUser, TOTP}

  @filter_keys ~w(q role status sort)

  def mount(_params, _session, socket) do
    can_manage = socket.assigns.tenant_role in ~w(owner admin)

    {:ok,
     socket
     |> stream_configure(:tenant_users, dom_id: &"portal-user-#{&1.id}")
     |> assign(
       page_title: "Users",
       min_password_length: Converger.Accounts.PasswordPolicy.min_length(),
       form: to_form(Accounts.change_tenant_user(%TenantUser{})),
       can_manage: can_manage,
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

    {:noreply, push_patch(socket, to: ~p"/portal/users?#{query}")}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more,
      do: {:noreply, load_page(socket, reset: false)},
      else: {:noreply, socket}
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
           |> assign(form: to_form(Accounts.change_tenant_user(%TenantUser{})))
           |> load_page(reset: true)}

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
          {:ok, updated} ->
            {:noreply,
             socket
             |> stream_insert(:tenant_users, updated)
             |> put_flash(:info, "Two-factor authentication reset for #{user.email}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to reset two-factor authentication")}
        end
    end
  end

  defp toggle_user_status(socket, user) do
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

  defp delete_user(socket, user) do
    case Accounts.delete_tenant_user(user, build_actor(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> stream_delete(:tenant_users, user)
         |> assign(loaded_count: max(socket.assigns.loaded_count - 1, 0))
         |> put_flash(:info, "User deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete user")}
    end
  end

  # Keyset page of the current tenant's users; the tenant scope comes from
  # the session, never from the URL.
  defp load_page(socket, reset: reset) do
    cursor = if reset, do: nil, else: socket.assigns.next_cursor
    filters = socket.assigns.filters

    scoped =
      filters
      |> Map.take(~w(q role status))
      |> Map.put("tenant_id", socket.assigns.current_tenant.id)

    page =
      case Accounts.paginate_tenant_users(scoped,
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
        <form id="portal-user-filter" phx-change="filter" phx-submit="filter">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
            <.input
              type="search"
              id="portal-user-filter-q"
              name="filters[q]"
              value={@filters["q"]}
              label="Search"
              placeholder="Name or email"
              phx-debounce="300"
            />
            <.input
              type="select"
              id="portal-user-filter-role"
              name="filters[role]"
              value={@filters["role"]}
              label="Role"
              options={[{"All", ""} | ~w(owner admin member viewer)]}
            />
            <.input
              type="select"
              id="portal-user-filter-status"
              name="filters[status]"
              value={@filters["status"]}
              label="Status"
              options={[{"All", ""} | ~w(active inactive)]}
            />
            <.input
              type="select"
              id="portal-user-filter-sort"
              name="filters[sort]"
              value={@filters["sort"]}
              label="Sort"
              options={[{"Newest first", "desc"}, {"Oldest first", "asc"}]}
            />
          </div>
        </form>

        <div class="overflow-x-auto">
          <.table id="portal-users" rows={@streams.tenant_users}>
            <:col :let={{_id, user}} label="Name"><span class="font-medium">{user.name}</span></:col>
            <:col :let={{_id, user}} label="Email">{user.email}</:col>
            <:col :let={{_id, user}} label="Role"><.badge value={user.role} /></:col>
            <:col :let={{_id, user}} label="Status"><.badge value={user.status} /></:col>
            <:col :let={{_id, user}} label="2FA">
              <.badge value={if TOTP.enabled?(user), do: "enabled", else: "disabled"}>
                {if TOTP.enabled?(user), do: "on", else: "off"}
              </.badge>
            </:col>
            <:col :let={{_id, user}} label="Joined">
              <span class="text-xs text-base-content/70">
                {Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M")}
              </span>
            </:col>
            <:action :let={{_id, user}} :if={@can_manage}>
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
        <.empty_state :if={@loaded_count == 0}>No users found.</.empty_state>
        <div class="flex items-center justify-between gap-2">
          <span class="text-sm text-base-content/60">Showing {@loaded_count} users</span>
          <.button
            :if={@has_more}
            id="load-more-portal-users"
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
