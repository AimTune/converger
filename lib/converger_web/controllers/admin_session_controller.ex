defmodule ConvergerWeb.AdminSessionController do
  use ConvergerWeb, :controller

  alias Converger.Accounts
  alias Converger.RateLimit.LoginThrottle
  alias ConvergerWeb.Plugs.RateLimit

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
      {:ok, %{must_change_password: true} = user} ->
        conn
        |> renew_session()
        |> put_session(:admin_user_id, user.id)
        |> put_flash(:info, "Please choose a new password before continuing.")
        |> redirect(to: "/admin/password")

      {:ok, user} ->
        conn
        |> renew_session()
        |> put_session(:admin_user_id, user.id)
        |> put_flash(:info, "Welcome back, #{user.name}!")
        |> redirect(to: "/admin")

      {:error, :inactive} ->
        render(conn, :new, error_message: "Your account has been deactivated.")

      {:error, :invalid_credentials} ->
        LoginThrottle.record_failure(conn.remote_ip, account)
        render(conn, :new, error_message: "Invalid email or password.")
    end
  end

  def delete(conn, _params) do
    conn
    |> renew_session()
    |> put_flash(:info, "Logged out successfully.")
    |> redirect(to: "/admin/login")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
