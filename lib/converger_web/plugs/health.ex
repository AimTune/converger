defmodule ConvergerWeb.Plugs.Health do
  @moduledoc """
  Serves `GET /health/live` and `GET /health/ready` for load balancers and
  Kubernetes probes. Unauthenticated and plain JSON.

  Plugged into `ConvergerWeb.Endpoint` before `TrustedProxies`, `ForceSSL`,
  request logging and telemetry, so probes over plain HTTP to the pod IP are
  never redirected to HTTPS and do not flood the logs. Any other request
  passes through untouched.

  * `/health/live` - always `200 {"status":"ok"}` while the VM answers.
  * `/health/ready` - `200 {"status":"ready","checks":{...}}` when every check
    of `Converger.Health.readiness/0` passes. Otherwise `503` with the failing
    `"reasons"`, every check result and `"status"`: `"draining"` when the node
    is shutting down (`ConvergerWeb.Drain`), else `"unavailable"`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method, path_info: ["health", check]} = conn, _opts)
      when method in ["GET", "HEAD"] and check in ["live", "ready"] do
    {status, body} = respond(check)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode_to_iodata!(body))
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp respond("live"), do: {200, %{status: "ok"}}

  defp respond("ready") do
    {result, checks} = Converger.Health.readiness()

    checks_json = Map.new(checks, fn {name, res} -> {name, format(res)} end)

    case result do
      :ok ->
        {200, %{status: "ready", checks: checks_json}}

      :error ->
        reasons = for {_name, {:error, reason}} <- checks, do: reason
        status = if checks[:draining] == :ok, do: "unavailable", else: "draining"
        {503, %{status: status, reasons: reasons, checks: checks_json}}
    end
  end

  defp format(:ok), do: "ok"
  defp format({:error, _reason}), do: "error"
end
