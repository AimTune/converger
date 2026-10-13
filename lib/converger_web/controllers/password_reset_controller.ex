defmodule ConvergerWeb.PasswordResetController do
  @moduledoc """
  Password reset by email (`/admin/password/reset`, behind the admin IP
  whitelist, and `/portal/password/reset`; `user_type` comes from the route
  assigns), see `Converger.Accounts.PasswordReset` and ADR-0058.

  The request form answers the same way whether or not an account matches.
  Requests are rate limited per client IP (`:password_reset_ip` bucket,
  answered with 429) and per account (`:password_reset_account`; over the
  limit no mail is sent, but the answer does not change).
  """
  use ConvergerWeb, :controller

  alias Converger.Accounts.{PasswordPolicy, PasswordReset}
  alias Converger.RateLimit
  alias ConvergerWeb.Plugs.RateLimit, as: RateLimitPlug
  alias ConvergerWeb.{SecurityController, UserAuth}

  plug :put_view, html: ConvergerWeb.AuthHTML

  def new(conn, _params), do: render_request(conn, sent: false)

  def create(conn, %{"reset" => params}) when is_map(params) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case RateLimit.check(:password_reset_ip, "ip:" <> ip) do
      {:allow, _} ->
        deliver(conn.assigns.user_type, params)
        render_request(conn, sent: true)

      {:deny, retry_after_ms, _spec} ->
        seconds = RateLimitPlug.retry_after_seconds(retry_after_ms)

        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(:too_many_requests)
        |> render_request(
          sent: false,
          error_message: "Too many requests. Try again in #{seconds} seconds."
        )
    end
  end

  def create(conn, _params), do: render_request(conn, sent: false)

  defp deliver(user_type, params) do
    email = String.trim(to_string(params["email"] || ""))
    tenant_name = String.trim(to_string(params["tenant_name"] || ""))
    account = String.downcase("#{user_type}:#{tenant_name}:#{email}")

    with true <- email != "",
         {:allow, _} <- RateLimit.check(:password_reset_account, account) do
      case user_type do
        "admin" ->
          PasswordReset.deliver_admin_instructions(email, &reset_url(user_type, &1))

        "tenant" ->
          PasswordReset.deliver_tenant_instructions(tenant_name, email, &reset_url(user_type, &1))
      end
    end

    :ok
  end

  defp reset_url(user_type, token) do
    ConvergerWeb.Endpoint.url() <> UserAuth.base_path(user_type) <> "/password/reset/" <> token
  end

  def edit(conn, %{"token" => token}) do
    if PasswordReset.get_user_by_token(conn.assigns.user_type, token) do
      render_edit(conn, token, [])
    else
      invalid_link(conn)
    end
  end

  def update(conn, %{"token" => token} = params) do
    reset = params["reset"] || %{}

    attrs = %{
      "password" => reset["password"],
      "password_confirmation" => reset["password_confirmation"]
    }

    case PasswordReset.reset_password(conn.assigns.user_type, token, attrs) do
      {:ok, _user} ->
        conn
        |> UserAuth.renew_session()
        |> put_flash(:info, "Password reset. Sign in with your new password.")
        |> redirect(to: UserAuth.base_path(conn.assigns.user_type) <> "/login")

      {:error, :invalid_token} ->
        invalid_link(conn)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_edit(token, SecurityController.error_messages(changeset))
    end
  end

  defp invalid_link(conn) do
    conn
    |> put_flash(:error, "The reset link is invalid or has expired.")
    |> redirect(to: UserAuth.base_path(conn.assigns.user_type) <> "/password/reset")
  end

  defp render_request(conn, opts) do
    render(conn, :reset_new,
      base: UserAuth.base_path(conn.assigns.user_type),
      sent: Keyword.fetch!(opts, :sent),
      error_message: Keyword.get(opts, :error_message)
    )
  end

  defp render_edit(conn, token, errors) do
    render(conn, :reset_edit,
      base: UserAuth.base_path(conn.assigns.user_type),
      token: token,
      errors: errors,
      min_length: PasswordPolicy.min_length()
    )
  end
end
