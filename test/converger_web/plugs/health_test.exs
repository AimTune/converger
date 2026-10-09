defmodule ConvergerWeb.Plugs.HealthTest do
  # Not async: draining and the migrations cache are node-global.
  use ConvergerWeb.ConnCase, async: false

  alias Converger.Health
  alias ConvergerWeb.Drain

  setup do
    Health.reset_migrations_cache()

    on_exit(fn ->
      Drain.reset()
      Health.reset_migrations_cache()
    end)
  end

  test "GET /health/live answers 200 without authentication", %{conn: conn} do
    conn = get(conn, "/health/live")

    assert json_response(conn, 200) == %{"status" => "ok"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "GET /health/ready is 200 with every check ok", %{conn: conn} do
    conn = get(conn, "/health/ready")

    assert json_response(conn, 200) == %{
             "status" => "ready",
             "checks" => %{
               "database" => "ok",
               "oban" => "ok",
               "draining" => "ok",
               "migrations" => "ok"
             }
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "GET /health/ready is 503 draining once the node drains (ConvergerWeb.Drain)", %{
    conn: conn
  } do
    Drain.start_draining()

    body = conn |> get("/health/ready") |> json_response(503)

    assert body["status"] == "draining"
    assert body["reasons"] == ["draining"]
    assert body["checks"]["draining"] == "error"
    assert body["checks"]["database"] == "ok"
  end

  test "GET /health/ready is 503 while a shipped migration is not applied", %{conn: conn} do
    latest = Enum.max(Health.release_migrations())

    # Rolled back with the sandbox transaction.
    Converger.Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [latest])

    body = conn |> get("/health/ready") |> json_response(503)

    assert body["status"] == "unavailable"
    assert body["reasons"] == ["migrations pending: 1"]
    assert body["checks"]["migrations"] == "error"
  end

  test "health probes are not redirected by ForceSSL", %{conn: conn} do
    previous = Application.get_env(:converger, :force_ssl)
    Application.put_env(:converger, :force_ssl, hsts: true, exclude: [])
    on_exit(fn -> restore(:force_ssl, previous) end)

    assert conn |> Map.put(:host, "10.1.2.3") |> get("/health/ready") |> Map.get(:status) == 200

    # The same plain HTTP request to any other path is redirected.
    assert build_conn() |> Map.put(:host, "10.1.2.3") |> get("/portal/login") |> Map.get(:status) ==
             301
  end

  test "other paths pass through", %{conn: conn} do
    conn = ConvergerWeb.Plugs.Health.call(%{conn | path_info: ["health"]}, [])
    refute conn.halted
  end

  defp restore(key, nil), do: Application.delete_env(:converger, key)
  defp restore(key, value), do: Application.put_env(:converger, key, value)
end
