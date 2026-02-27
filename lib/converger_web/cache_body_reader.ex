defmodule ConvergerWeb.CacheBodyReader do
  @moduledoc """
  Caches the raw request body for webhook signature verification.
  Only caches for paths matching inbound webhook endpoints.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        if should_cache?(conn) do
          {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
        else
          {:ok, body, conn}
        end

      {:more, body, conn} ->
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp should_cache?(conn) do
    String.contains?(conn.request_path, "/channels/") and
      String.contains?(conn.request_path, "/inbound")
  end
end
