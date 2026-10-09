defmodule ConvergerWeb.Plugs.Health do
  @moduledoc """
  Unauthenticated probes for load balancers and Kubernetes:

    * `GET /health/live` - 200 while the node is up.
    * `GET /health/ready` - 200 `{"status":"ready"}`, or 503
      `{"status":"draining"}` once the node has started shutting down
      (`ConvergerWeb.Drain`), so new traffic goes to other nodes.

  Further readiness checks (database, Oban, migrations) are planned in
  [#29](https://github.com/AimTune/converger/issues/29).
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method, path_info: ["health", "live"]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    respond(conn, 200, "ok")
  end

  def call(%Plug.Conn{method: method, path_info: ["health", "ready"]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    if ConvergerWeb.Drain.draining?(),
      do: respond(conn, 503, "draining"),
      else: respond(conn, 200, "ready")
  end

  def call(conn, _opts), do: conn

  defp respond(conn, status, value) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(%{status: value}))
    |> halt()
  end
end
