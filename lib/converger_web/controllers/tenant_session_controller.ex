defmodule ConvergerWeb.TenantSessionController do
  use ConvergerWeb, :controller

  alias Converger.Accounts

  def new(conn, _params) do
    if conn.assigns[:current_tenant_user] do
      redirect(conn, to: "/portal")
    else
      render(conn, :new, error_message: nil)
    end
  end

  def create(conn, %{"email" => email, "password" => password, "tenant_name" => tenant_name}) do
    case Accounts.authenticate_tenant_user_by_name(email, password, tenant_name) do
      {:ok, user} ->
        conn
        |> renew_session()
        |> put_session(:tenant_user_id, user.id)
        |> put_flash(:info, "Welcome back, #{user.name}!")
        |> redirect(to: "/portal")

      {:error, :inactive} ->
        render(conn, :new, error_message: "Your account has been deactivated.")

      {:error, :invalid_credentials} ->
        render(conn, :new, error_message: "Invalid tenant, email, or password.")
    end
  end

  def delete(conn, _params) do
    conn
    |> renew_session()
    |> put_flash(:info, "Logged out successfully.")
    |> redirect(to: "/portal/login")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
