defmodule ConvergerWeb.Plugs.Auth do
  @moduledoc """
  Authentication plugs for admin and tenant user sessions.

  The cookie session carries the token of a server-side session
  (`Converger.Accounts.Sessions`, ADR-0058); the fetch plugs validate it
  (row present, absolute lifetime, idle timeout, active user) on every
  request and assign `:current_user_session` with the session row.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Converger.Accounts.{Sessions, TOTP}
  alias ConvergerWeb.UserAuth

  def fetch_admin_user(conn, _opts) do
    case fetch_session_user(conn, "admin") do
      {:ok, conn, user} -> assign(conn, :current_admin_user, user)
      {:error, conn} -> assign(conn, :current_admin_user, nil)
    end
  end

  def fetch_tenant_user(conn, _opts) do
    case fetch_session_user(conn, "tenant") do
      {:ok, conn, user} ->
        conn
        |> assign(:current_tenant_user, user)
        |> assign(:current_tenant, user.tenant)

      {:error, conn} ->
        conn
        |> assign(:current_tenant_user, nil)
        |> assign(:current_tenant, nil)
    end
  end

  defp fetch_session_user(conn, user_type) do
    key = UserAuth.token_key(user_type)
    token = get_session(conn, key)

    case Sessions.validate(user_type, token) do
      {:ok, session, user} ->
        {:ok, assign(conn, :current_user_session, session), user}

      {:error, _} when is_binary(token) ->
        {:error, conn |> delete_session(key) |> delete_session(:live_socket_id)}

      {:error, _} ->
        {:error, conn}
    end
  end

  @doc """
  Requires a logged-in admin who has no pending forced password change and,
  when their role requires 2FA (`:require_2fa_roles`), has enabled it.
  Admins flagged `must_change_password` are sent to `/admin/password`
  first, admins without required 2FA to `/admin/security`.
  """
  def require_admin_user(conn, opts) do
    conn = require_admin_session(conn, opts)
    user = conn.assigns[:current_admin_user]

    cond do
      conn.halted ->
        conn

      user.must_change_password ->
        conn
        |> put_flash(:error, "You must change your password before continuing.")
        |> redirect(to: "/admin/password")
        |> halt()

      TOTP.enrollment_required?(user) ->
        conn
        |> put_flash(
          :error,
          "Your role requires two-factor authentication. Set it up to continue."
        )
        |> redirect(to: "/admin/security")
        |> halt()

      true ->
        conn
    end
  end

  @doc """
  Requires a logged-in admin, without enforcing `must_change_password` or
  required 2FA. Used by the password change and security pages themselves.
  """
  def require_admin_session(conn, _opts) do
    if conn.assigns[:current_admin_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: "/admin/login")
      |> halt()
    end
  end

  def require_tenant_user(conn, _opts) do
    if conn.assigns[:current_tenant_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: "/portal/login")
      |> halt()
    end
  end

  def redirect_if_admin_authenticated(conn, _opts) do
    if conn.assigns[:current_admin_user] do
      conn
      |> redirect(to: "/admin")
      |> halt()
    else
      conn
    end
  end

  def redirect_if_tenant_authenticated(conn, _opts) do
    if conn.assigns[:current_tenant_user] do
      conn
      |> redirect(to: "/portal")
      |> halt()
    else
      conn
    end
  end
end
