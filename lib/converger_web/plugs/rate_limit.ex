defmodule ConvergerWeb.Plugs.RateLimit do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, opts) do
    case check_rate_limit(conn, opts) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many requests. Please try again later."})
        |> halt()
    end
  end

  defp check_rate_limit(conn, opts) do
    # opts: [key_prefix: "prefix", limit: 5, scale_ms: 60000]
    key = make_key(conn, opts[:scope] || :ip, opts[:key_prefix] || "rl")
    limit = opts[:limit] || 10
    scale = opts[:scale_ms] || 60_000

    Hammer.check_rate(key, scale, limit)
  end

  defp make_key(conn, :ip, prefix) do
    ip = conn.remote_ip |> Tuple.to_list() |> Enum.join(".")
    "#{prefix}:ip:#{ip}"
  end

  defp make_key(conn, :tenant, prefix) do
    tenant_id = (conn.assigns[:tenant] && conn.assigns[:tenant].id) || "anonymous"
    "#{prefix}:tenant:#{tenant_id}"
  end
end
