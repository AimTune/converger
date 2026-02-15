defmodule ConvergerWeb.Plugs.RateLimitTest do
  use ConvergerWeb.ConnCase, async: true
  alias ConvergerWeb.Plugs.RateLimit

  setup do
    # Clear Hammer ETS backend before each test if possible,
    # but Hammer uses a named ETS table so we might just use unique keys.
    %{key_prefix: "test_#{System.unique_integer()}"}
  end

  test "allows requests under the limit", %{conn: conn, key_prefix: prefix} do
    opts = RateLimit.init(scope: :ip, key_prefix: prefix, limit: 5, scale_ms: 60_000)

    conn = RateLimit.call(conn, opts)
    refute conn.halted
    assert conn.status != 429
  end

  test "blocks requests over the limit", %{conn: conn, key_prefix: prefix} do
    opts = RateLimit.init(scope: :ip, key_prefix: prefix, limit: 1, scale_ms: 60_000)

    # First request - allow
    conn = RateLimit.call(conn, opts)
    refute conn.halted

    # Second request - deny
    conn2 = RateLimit.call(conn, opts)
    assert conn2.halted
    assert conn2.status == 429
    assert json_response(conn2, 429)["error"] =~ "Too many requests"
  end

  test "scopes by tenant if requested", %{conn: conn, key_prefix: prefix} do
    tenant = %{id: "tenant_1"}
    conn = assign(conn, :tenant, tenant)

    opts = RateLimit.init(scope: :tenant, key_prefix: prefix, limit: 1, scale_ms: 60_000)

    # First request for tenant_1 - allow
    conn = RateLimit.call(conn, opts)
    refute conn.halted

    # Second request for tenant_1 - deny
    conn2 = RateLimit.call(conn, opts)
    assert conn2.halted

    # Request for different tenant - allow
    conn3 = assign(build_conn(), :tenant, %{id: "tenant_2"})
    conn3 = RateLimit.call(conn3, opts)
    refute conn3.halted
  end
end
