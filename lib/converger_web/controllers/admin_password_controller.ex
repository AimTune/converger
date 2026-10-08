defmodule ConvergerWeb.AdminPasswordController do
  @moduledoc """
  Lets a logged-in admin change their own password. Admins flagged
  `must_change_password` (e.g. the bootstrap account with a generated
  password) are redirected here until they do.
  """
  use ConvergerWeb, :controller

  alias Converger.Accounts

  def edit(conn, _params) do
    render(conn, :edit, errors: [], forced: forced?(conn))
  end

  def update(conn, %{"admin_password" => params}) do
    user = conn.assigns.current_admin_user

    new_attrs = %{
      "password" => params["password"],
      "password_confirmation" => params["password_confirmation"]
    }

    case Accounts.change_admin_password(user, params["current_password"] || "", new_attrs) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Password updated.")
        |> redirect(to: "/admin")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:edit, errors: error_messages(changeset), forced: forced?(conn))
    end
  end

  def update(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:edit, errors: ["All fields are required."], forced: forced?(conn))
  end

  defp forced?(conn), do: conn.assigns.current_admin_user.must_change_password

  defp error_messages(changeset) do
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
