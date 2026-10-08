defmodule ConvergerWeb.CacheBodyReader do
  @moduledoc """
  Caches the raw request body for webhook signature verification.

  The body is cached (in `conn.assigns.raw_body`) for every
  `/api/v1/channels/*` route, so both `/inbound` and `/status` can verify
  signatures over the exact bytes that were sent. Bodies read in several
  chunks are accumulated.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, maybe_cache(conn, body)}

      {:more, body, conn} ->
        {:more, body, maybe_cache(conn, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_cache(conn, body) do
    if should_cache?(conn) do
      Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)
    else
      conn
    end
  end

  defp should_cache?(conn) do
    String.starts_with?(conn.request_path, "/api/v1/channels/")
  end
end
