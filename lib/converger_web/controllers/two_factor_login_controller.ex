defmodule ConvergerWeb.TwoFactorLoginController do
  @moduledoc """
  Second login step for users with TOTP 2FA (`/admin/login/totp`,
  `/portal/login/totp`; `user_type` comes from the route assigns).

  The password step leaves a pending login in the cookie session (five
  minutes, `ConvergerWeb.UserAuth.put_pending_2fa/3`). Wrong codes are
  throttled by `Converger.RateLimit.LoginThrottle` per IP and per account
  (`"<type>-2fa:<user id>"`).
  """
  use ConvergerWeb, :controller

  alias Converger.Accounts.TOTP
  alias Converger.RateLimit.LoginThrottle
  alias ConvergerWeb.{AdminSessionController, TenantSessionController, UserAuth}
  alias ConvergerWeb.Plugs.RateLimit

  plug :put_view, html: ConvergerWeb.AuthHTML

  def new(conn, _params) do
    user_type = conn.assigns.user_type

    case UserAuth.pending_2fa_user(conn, user_type) do
      {:ok, _user} -> render_form(conn, nil)
      :error -> restart(conn, user_type)
    end
  end

  def create(conn, params) do
    user_type = conn.assigns.user_type

    case UserAuth.pending_2fa_user(conn, user_type) do
      {:ok, user} -> check_code(conn, user_type, user, params["code"])
      :error -> restart(conn, user_type)
    end
  end

  defp check_code(conn, user_type, user, code) do
    account = user_type <> "-2fa:" <> user.id

    with :ok <- LoginThrottle.check(conn.remote_ip, account),
         :ok <- TOTP.verify(user, code) do
      case user_type do
        "admin" -> AdminSessionController.log_in(conn, user)
        "tenant" -> TenantSessionController.log_in(conn, user)
      end
    else
      {:error, retry_after_ms} ->
        seconds = RateLimit.retry_after_seconds(retry_after_ms)

        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(:too_many_requests)
        |> render_form("Too many failed attempts. Try again in #{seconds} seconds.")

      :error ->
        LoginThrottle.record_failure(conn.remote_ip, account)

        conn
        |> put_status(:unprocessable_entity)
        |> render_form("Invalid or already used code.")
    end
  end

  defp render_form(conn, error_message) do
    render(conn, :totp_login,
      base: UserAuth.base_path(conn.assigns.user_type),
      error_message: error_message
    )
  end

  defp restart(conn, user_type) do
    conn
    |> put_flash(:error, "Your login expired. Please sign in again.")
    |> redirect(to: UserAuth.base_path(user_type) <> "/login")
  end
end
