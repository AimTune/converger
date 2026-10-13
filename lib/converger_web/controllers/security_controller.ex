defmodule ConvergerWeb.SecurityController do
  @moduledoc """
  Security settings of the logged-in user (`/admin/security`,
  `/portal/security`; `user_type` comes from the route assigns), ADR-0058:

    * TOTP 2FA enrollment (secret + `otpauth://` URI, confirmed with a code)
      and turning it off (with a current code or the password);
    * the user's sessions: sign out one, or log out everywhere;
    * own password change (portal; admins use `/admin/password`).

  Admins whose role requires 2FA are sent here until they enable it, so the
  admin routes only require a session, not the full admin checks.
  """
  use ConvergerWeb, :controller

  alias Converger.Accounts
  alias Converger.Accounts.{Audit, PasswordPolicy, Sessions, TOTP}
  alias ConvergerWeb.UserAuth

  plug :put_view, html: ConvergerWeb.AuthHTML
  plug :put_type_root_layout

  def show(conn, _params), do: render_page(conn)

  def setup_totp(conn, _params) do
    case TOTP.begin_enrollment(user(conn)) do
      {:ok, _user} -> redirect(conn, to: type_path(conn, "/security#two-factor"))
      {:error, :already_enabled} -> redirect(conn, to: type_path(conn, "/security"))
    end
  end

  def confirm_totp(conn, params) do
    case TOTP.confirm_enrollment(user(conn), params["code"] || "") do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Two-factor authentication is on.")
        |> redirect(to: type_path(conn, "/security"))

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_page(error_message: "That code is not valid. Check the app and try again.")
    end
  end

  def disable_totp(conn, params) do
    case TOTP.disable(user(conn), params["code_or_password"]) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Two-factor authentication is off.")
        |> redirect(to: type_path(conn, "/security"))

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_page(error_message: "Invalid code or password.")
    end
  end

  def delete_session(conn, %{"id" => id}) do
    user = user(conn)

    if Sessions.delete(conn.assigns.user_type, user.id, id) > 0 do
      Audit.log(user, Audit.self_actor(user), "revoke_sessions", %{"sessions" => 1})
    end

    conn
    |> put_flash(:info, "Session signed out.")
    |> redirect(to: type_path(conn, "/security"))
  end

  def log_out_everywhere(conn, _params) do
    user = user(conn)
    Accounts.revoke_sessions(user, Audit.self_actor(user))

    conn
    |> UserAuth.renew_session()
    |> put_flash(:info, "You have been logged out of every session.")
    |> redirect(to: type_path(conn, "/login"))
  end

  def update_password(conn, %{"password" => params}) do
    user = user(conn)

    attrs = %{
      "password" => params["password"],
      "password_confirmation" => params["password_confirmation"]
    }

    case Accounts.change_own_password(user, params["current_password"] || "", attrs,
           keep_session_id: conn.assigns.current_user_session.id
         ) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Password updated. Your other sessions were signed out.")
        |> redirect(to: type_path(conn, "/security"))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_page(password_errors: error_messages(changeset))
    end
  end

  def update_password(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> render_page(password_errors: ["All fields are required."])
  end

  defp render_page(conn, extra \\ []) do
    user = user(conn)
    session = conn.assigns.current_user_session

    render(
      conn,
      :security,
      Keyword.merge(
        [
          base: UserAuth.base_path(conn.assigns.user_type),
          user: user,
          page_title: "Security",
          required: TOTP.enrollment_required?(user),
          totp_enabled: TOTP.enabled?(user),
          totp_pending: TOTP.pending?(user),
          secret: TOTP.base32_secret(user),
          otpauth_uri: TOTP.otpauth_uri(user),
          sessions: Sessions.list(conn.assigns.user_type, user.id),
          current_session_id: session.id,
          max_age_hours: hours(Sessions.max_age_seconds()),
          idle_minutes: div(Sessions.idle_timeout_seconds(), 60),
          min_length: PasswordPolicy.min_length(),
          password_errors: [],
          error_message: nil
        ],
        extra
      )
    )
  end

  defp hours(seconds) when rem(seconds, 3600) == 0, do: div(seconds, 3600)
  defp hours(seconds), do: Float.round(seconds / 3600, 1)

  defp user(conn), do: UserAuth.current_user(conn, conn.assigns.user_type)

  defp type_path(conn, suffix), do: UserAuth.base_path(conn.assigns.user_type) <> suffix

  defp put_type_root_layout(conn, _opts) do
    case conn.assigns.user_type do
      "admin" -> put_root_layout(conn, html: {ConvergerWeb.Layouts, :admin_root})
      "tenant" -> put_root_layout(conn, html: {ConvergerWeb.Layouts, :portal_root})
    end
  end

  @doc false
  def error_messages(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      label = field |> to_string() |> String.replace("_", " ") |> String.capitalize()
      Enum.map(messages, &"#{label} #{&1}")
    end)
  end
end
