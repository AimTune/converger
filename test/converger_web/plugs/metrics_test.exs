defmodule ConvergerWeb.Plugs.MetricsTest do
  # Not async: changes the :metrics application env.
  use ConvergerWeb.ConnCase, async: false

  alias ConvergerWeb.Plugs.Metrics

  setup do
    previous = Application.get_env(:converger, :metrics)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :metrics, previous),
        else: Application.delete_env(:converger, :metrics)
    end)
  end

  defp configure(config), do: Application.put_env(:converger, :metrics, config)

  test "is disabled (404) when neither a token nor an IP allowlist is configured", %{conn: conn} do
    configure([])

    assert conn |> get("/metrics") |> Map.get(:status) == 404
  end

  test "serves Prometheus text with the right bearer token", %{conn: conn} do
    configure(token: "s3cret-metrics-token")

    conn =
      conn |> put_req_header("authorization", "Bearer s3cret-metrics-token") |> get("/metrics")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"
    assert conn.resp_body =~ "# TYPE"
  end

  test "rejects a wrong or missing token with 401", %{conn: conn} do
    configure(token: "s3cret-metrics-token")

    wrong = conn |> put_req_header("authorization", "Bearer nope") |> get("/metrics")
    assert wrong.status == 401
    assert get_resp_header(wrong, "www-authenticate") == [~s(Bearer realm="metrics")]

    assert build_conn() |> get("/metrics") |> Map.get(:status) == 401
  end

  test "allows clients from METRICS_ALLOWED_IPS without a token", %{conn: conn} do
    configure(allowed_ips: ["10.0.0.0/8"])

    allowed = conn |> Map.put(:remote_ip, {10, 1, 2, 3}) |> get("/metrics")
    assert allowed.status == 200

    denied = build_conn() |> Map.put(:remote_ip, {192, 0, 2, 1}) |> get("/metrics")
    assert denied.status == 401
  end

  test "the standalone listener serves /metrics unauthenticated and 404s elsewhere", %{conn: conn} do
    configure([])
    opts = Metrics.init(standalone: true)

    assert Metrics.call(%{conn | path_info: ["metrics"]}, opts).status == 200
    assert Metrics.call(%{conn | path_info: ["other"]}, opts).status == 404
  end

  test "other paths pass through the endpoint plug", %{conn: conn} do
    configure(token: "t")

    conn = Metrics.call(%{conn | path_info: ["api"]}, Metrics.init([]))
    refute conn.halted
  end
end
