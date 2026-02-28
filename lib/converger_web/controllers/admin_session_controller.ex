defmodule ConvergerWeb.AdminSessionController do
  use ConvergerWeb, :controller

  alias Converger.Accounts

  def new(conn, _params) do
    if conn.assigns[:current_admin_user] do
      redirect(conn, to: "/admin")
    else
      render(conn, :new, error_message: nil)
    end
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate_admin(email, password) do
      {:ok, user} ->
        conn
        |> renew_session()
        |> put_session(:admin_user_id, user.id)
        |> put_flash(:info, "Welcome back, #{user.name}!")
        |> redirect(to: "/admin")

      {:error, :inactive} ->
        render(conn, :new, error_message: "Your account has been deactivated.")

      {:error, :invalid_credentials} ->
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
