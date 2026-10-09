defmodule ConvergerWeb.Plugs.HealthTest do
  use ConvergerWeb.ConnCase, async: false

  alias ConvergerWeb.Drain

  setup do
    on_exit(&Drain.reset/0)
  end

  test "GET /health/live is 200", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get("/health/live") |> json_response(200)
  end

  test "GET /health/ready is 200 until the node drains, then 503", %{conn: conn} do
    assert %{"status" => "ready"} = conn |> get("/health/ready") |> json_response(200)

    Drain.start_draining()

    assert %{"status" => "draining"} =
             build_conn() |> get("/health/ready") |> json_response(503)
  end

  test "the probes are not redirected to HTTPS", %{conn: conn} do
    conn = get(conn, "/health/live")
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
