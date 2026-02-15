defmodule ConvergerWeb.FallbackController do
  @moduledoc """
  Translates controller return values to Plug.Conn responses.

  For example, if a controller returns `{:error, :not_found}`,
  this module will translate it to a 404 JSON response.
  """
  use ConvergerWeb, :controller

  # This clause handles errors returned by Ecto's insert/update/delete.
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ConvergerWeb.ErrorJSON)
    |> render(:error, changeset: changeset)
  end

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: ConvergerWeb.ErrorJSON)
    |> render(:"404")
  end
end
