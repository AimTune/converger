defmodule ConvergerWeb.AdminSessionController do
  @moduledoc """
  Admin login and logout. A correct password starts a server-side session
  (`ConvergerWeb.UserAuth`), or, for admins with 2FA, a pending login that
  `ConvergerWeb.TwoFactorLoginController` completes.
  """
  use ConvergerWeb, :controller

  alias Converger.Accounts
  alias Converger.Accounts.TOTP
  alias Converger.RateLimit.LoginThrottle
  alias ConvergerWeb.Plugs.RateLimit
  alias ConvergerWeb.UserAuth

  def new(conn, _params) do
    if conn.assigns[:current_admin_user] do
      redirect(conn, to: "/admin")
    else
      render(conn, :new, error_message: nil)
    end
  end

  def create(conn, %{"email" => email, "password" => password}) do
    account = "admin:" <> email

    case LoginThrottle.check(conn.remote_ip, account) do
      :ok ->
        authenticate(conn, email, password, account)

      {:error, retry_after_ms} ->
        seconds = RateLimit.retry_after_seconds(retry_after_ms)

        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(:too_many_requests)
        |> render(:new,
          error_message: "Too many failed login attempts. Try again in #{seconds} seconds."
        )
    end
  end

  defp authenticate(conn, email, password, account) do
    case Accounts.authenticate_admin(email, password) do
      {:ok, user} ->
        if TOTP.enabled?(user) do
          conn
          |> UserAuth.put_pending_2fa("admin", user)
          |> redirect(to: "/admin/login/totp")
        else
          log_in(conn, user)
        end

      {:error, :inactive} ->
        render(conn, :new, error_message: "Your account has been deactivated.")

      {:error, :invalid_credentials} ->
        LoginThrottle.record_failure(conn.remote_ip, account)
        render(conn, :new, error_message: "Invalid email or password.")
    end
  end

  @doc false
  def log_in(conn, %{must_change_password: true} = user) do
    conn
    |> UserAuth.log_in("admin", user)
    |> put_flash(:info, "Please choose a new password before continuing.")
    |> redirect(to: "/admin/password")
  end

  def log_in(conn, user) do
    conn
    |> UserAuth.log_in("admin", user)
    |> put_flash(:info, "Welcome back, #{user.name}!")
    |> redirect(to: "/admin")
  end

  def delete(conn, _params) do
    conn
    |> UserAuth.log_out("admin")
    |> put_flash(:info, "Logged out successfully.")
    |> redirect(to: "/admin/login")
  end
end
