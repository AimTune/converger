defmodule ConvergerWeb.Plugs.AdminAuth do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    remote_ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    # In a real app, load this from ENV. For now, localhost only.
    whitelist = ["127.0.0.1", "::1"]

    if remote_ip in whitelist do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> text("Forbidden")
      |> halt()
    end
  end
end
