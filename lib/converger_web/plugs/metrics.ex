defmodule ConvergerWeb.Plugs.Metrics do
  @moduledoc """
  Serves the Prometheus metrics (`ConvergerWeb.Telemetry`) at `GET /metrics`
  on the main HTTP port.

  Access is granted when either

    * the request carries `Authorization: Bearer <token>` matching
      `METRICS_TOKEN` (`config :converger, :metrics, token: ...`), or
    * the client IP (`conn.remote_ip`, as resolved by
      `ConvergerWeb.Plugs.TrustedProxies`) is in `METRICS_ALLOWED_IPS`
      (`allowed_ips: [...]`, addresses or CIDR ranges).

  Secure by default: with neither configured, `/metrics` answers `404` as if
  it did not exist. With either configured, other requests get `401`.

  Plugged into the endpoint after `TrustedProxies` and before `ForceSSL`, so
  in-cluster scrapes over plain HTTP to the pod IP work. Any other path
  passes through.

  With `standalone: true` (the opt-in `PROMETHEUS_PORT` listener) every
  request to `/metrics` is served without authentication and every other
  path is answered with `404`.
  """

  @behaviour Plug

  import Plug.Conn

  alias ConvergerWeb.IpMatcher

  @registry :converger_metrics

  @doc "Name of the `TelemetryMetricsPrometheus.Core` registry."
  def registry, do: @registry

  @impl true
  def init(opts), do: Keyword.get(opts, :standalone, false)

  @impl true
  def call(%Plug.Conn{method: method, path_info: ["metrics"]} = conn, standalone?)
      when method in ["GET", "HEAD"] do
    case authorize(conn, standalone?) do
      :ok -> scrape(conn)
      :disabled -> conn |> send_resp(404, "Not Found") |> halt()
      :unauthorized -> unauthorized(conn)
    end
  end

  def call(conn, true = _standalone?), do: conn |> send_resp(404, "Not Found") |> halt()
  def call(conn, _standalone?), do: conn

  defp authorize(_conn, true), do: :ok

  defp authorize(conn, false) do
    config = Application.get_env(:converger, :metrics, [])
    token = Keyword.get(config, :token)
    allowed_ips = Keyword.get(config, :allowed_ips, [])

    cond do
      token in [nil, ""] and allowed_ips == [] -> :disabled
      valid_token?(conn, token) -> :ok
      ip_allowed?(conn, allowed_ips) -> :ok
      true -> :unauthorized
    end
  end

  defp valid_token?(_conn, token) when token in [nil, ""], do: false

  defp valid_token?(conn, token) do
    Enum.any?(get_req_header(conn, "authorization"), fn header ->
      case String.split(header, " ", parts: 2) do
        [scheme, given] ->
          String.downcase(scheme) == "bearer" and
            Plug.Crypto.secure_compare(String.trim(given), token)

        _ ->
          false
      end
    end)
  end

  defp ip_allowed?(_conn, []), do: false

  defp ip_allowed?(conn, allowed_ips),
    do: IpMatcher.member?(conn.remote_ip, IpMatcher.parse_list_cached(allowed_ips))

  defp scrape(conn) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4", nil)
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape(@registry))
    |> halt()
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="metrics"))
    |> send_resp(401, "Unauthorized")
    |> halt()
  end
end
