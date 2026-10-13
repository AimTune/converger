defmodule ConvergerWeb.TenantSessionController do
  @moduledoc """
  Tenant portal login and logout. A correct password starts a server-side
  session (`ConvergerWeb.UserAuth`), or, for users with 2FA, a pending login
  that `ConvergerWeb.TwoFactorLoginController` completes.
  """
  use ConvergerWeb, :controller

  alias Converger.Accounts
  alias Converger.Accounts.TOTP
  alias Converger.RateLimit.LoginThrottle
  alias ConvergerWeb.Plugs.RateLimit
  alias ConvergerWeb.UserAuth

  def new(conn, _params) do
    if conn.assigns[:current_tenant_user] do
      redirect(conn, to: "/portal")
    else
      render(conn, :new, error_message: nil)
    end
  end

  def create(conn, %{"email" => email, "password" => password, "tenant_name" => tenant_name}) do
    account = "tenant:" <> tenant_name <> ":" <> email

    case LoginThrottle.check(conn.remote_ip, account) do
      :ok ->
        authenticate(conn, email, password, tenant_name, account)

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

  defp authenticate(conn, email, password, tenant_name, account) do
    case Accounts.authenticate_tenant_user_by_name(email, password, tenant_name) do
      {:ok, user} ->
        if TOTP.enabled?(user) do
          conn
          |> UserAuth.put_pending_2fa("tenant", user)
          |> redirect(to: "/portal/login/totp")
        else
          log_in(conn, user)
        end

      {:error, :inactive} ->
        render(conn, :new, error_message: "Your account has been deactivated.")

      {:error, :invalid_credentials} ->
        LoginThrottle.record_failure(conn.remote_ip, account)
        render(conn, :new, error_message: "Invalid tenant, email, or password.")
    end
  end

  @doc false
  def log_in(conn, user) do
    conn
    |> UserAuth.log_in("tenant", user)
    |> put_flash(:info, "Welcome back, #{user.name}!")
    |> redirect(to: "/portal")
  end

  def delete(conn, _params) do
    conn
    |> UserAuth.log_out("tenant")
    |> put_flash(:info, "Logged out successfully.")
    |> redirect(to: "/portal/login")
  end
end
