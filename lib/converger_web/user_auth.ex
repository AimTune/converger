defmodule ConvergerWeb.UserAuth do
  @moduledoc """
  Browser login state of the admin panel (`user_type` `"admin"`) and the
  tenant portal (`"tenant"`), see ADR-0058.

  The cookie session holds the token of a server-side session
  (`Converger.Accounts.Sessions`) under `:admin_session_token` or
  `:tenant_session_token`, plus the `live_socket_id` of that session.
  Between a correct password and a correct 2FA code it holds only a pending
  login (`"pending_2fa"`: user type, id and time), valid for five minutes.
  """

  import Plug.Conn

  alias Converger.Accounts
  alias Converger.Accounts.{AdminUser, Sessions, TenantUser}

  @pending_key "pending_2fa"
  @pending_ttl_seconds 300

  @doc "The cookie session key holding the session token of `user_type`."
  def token_key("admin"), do: :admin_session_token
  def token_key("tenant"), do: :tenant_session_token

  @doc "The path prefix of `user_type` (`/admin` or `/portal`)."
  def base_path("admin"), do: "/admin"
  def base_path("tenant"), do: "/portal"

  @doc "The logged-in user of `user_type` (from the fetch plugs)."
  def current_user(conn, "admin"), do: conn.assigns[:current_admin_user]
  def current_user(conn, "tenant"), do: conn.assigns[:current_tenant_user]

  @doc """
  Creates a server-side session for `user` and stores its token in a fresh
  cookie session (session fixation: the old cookie session is dropped).
  """
  def log_in(conn, user_type, user) do
    {:ok, token, session} = Sessions.create(user_type, user, client_info(conn))

    conn
    |> renew_session()
    |> put_session(token_key(user_type), token)
    |> put_session(:live_socket_id, Sessions.live_socket_id(session))
  end

  @doc "Deletes the current server-side session and clears the cookie session."
  def log_out(conn, user_type) do
    Sessions.delete_by_token(user_type, get_session(conn, token_key(user_type)))
    renew_session(conn)
  end

  @doc "Drops the cookie session and issues a new session id."
  def renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc "Remembers a password-verified login waiting for its 2FA code."
  def put_pending_2fa(conn, user_type, user) do
    conn
    |> renew_session()
    |> put_session(@pending_key, %{
      "type" => user_type,
      "id" => user.id,
      "at" => System.system_time(:second)
    })
  end

  @doc """
  The active user of the pending 2FA login of `user_type`, or `:error` when
  there is none or it is older than five minutes.
  """
  def pending_2fa_user(conn, user_type) do
    with %{"type" => ^user_type, "id" => id, "at" => at} <- get_session(conn, @pending_key),
         true <- System.system_time(:second) - at <= @pending_ttl_seconds,
         %{status: "active"} = user <- get_user(user_type, id) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp get_user("admin", id), do: Converger.Repo.get(AdminUser, id)

  defp get_user("tenant", id) do
    case Converger.Repo.get(TenantUser, id) do
      nil -> nil
      user -> Converger.Repo.preload(user, :tenant)
    end
  end

  @doc "Where a freshly logged-in user goes first."
  def signed_in_path(%AdminUser{must_change_password: true}), do: "/admin/password"
  def signed_in_path(%AdminUser{}), do: "/admin"
  def signed_in_path(%TenantUser{}), do: "/portal"

  @doc "The user type of a user struct."
  def user_type(user), do: Accounts.user_type(user)

  defp client_info(conn) do
    %{
      ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: conn |> get_req_header("user-agent") |> List.first()
    }
  end
end
