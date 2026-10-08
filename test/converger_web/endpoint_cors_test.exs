defmodule ConvergerWeb.EndpointCORSTest do
  # Mutates the global :cors_origins application env, so it must not run async.
  use ConvergerWeb.ConnCase, async: false

  @allowed "https://app.example.com"
  @other "https://other.example.com"

  setup do
    original = Application.fetch_env(:converger, :cors_origins)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:converger, :cors_origins, value)
        :error -> Application.delete_env(:converger, :cors_origins)
      end
    end)

    :ok
  end

  defp preflight(conn, origin) do
    conn
    |> put_req_header("origin", origin)
    |> put_req_header("access-control-request-method", "POST")
    |> options("/api/v1/activities")
  end

  # An unauthenticated request: the router rejects it, but CORS headers are
  # added by the endpoint before routing.
  defp simple_request(conn, origin) do
    conn
    |> put_req_header("origin", origin)
    |> get("/api/v1/activities")
  end

  test "preflight honours cors_origins changed at runtime", %{conn: conn} do
    Application.put_env(:converger, :cors_origins, [@other])

    conn1 = preflight(conn, @allowed)
    assert conn1.status == 204
    assert get_resp_header(conn1, "access-control-allow-origin") == []

    Application.put_env(:converger, :cors_origins, [@allowed])

    conn2 = preflight(build_conn(), @allowed)
    assert conn2.status == 204
    assert get_resp_header(conn2, "access-control-allow-origin") == [@allowed]
    assert [methods] = get_resp_header(conn2, "access-control-allow-methods")
    assert methods =~ "POST"

    conn3 = preflight(build_conn(), @other)
    assert get_resp_header(conn3, "access-control-allow-origin") == []
  end

  test "non-preflight requests also use the runtime origins", %{conn: conn} do
    Application.put_env(:converger, :cors_origins, [@allowed])
    conn1 = simple_request(conn, @allowed)
    assert get_resp_header(conn1, "access-control-allow-origin") == [@allowed]

    Application.put_env(:converger, :cors_origins, [@other])
    conn2 = simple_request(build_conn(), @allowed)
    assert get_resp_header(conn2, "access-control-allow-origin") == []
  end

  test "a wildcard origin is supported", %{conn: conn} do
    Application.put_env(:converger, :cors_origins, ["*"])
    conn = preflight(conn, @allowed)
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end
end
