defmodule ConvergerWeb.Plugs.AdminAuthTest do
  use ConvergerWeb.ConnCase

  alias ConvergerWeb.Plugs.AdminAuth

  test "permits allowed IP", %{conn: conn} do
    conn = %{conn | remote_ip: {127, 0, 0, 1}}
    conn = AdminAuth.call(conn, AdminAuth.init([]))
    refute conn.halted
  end

  test "blocks unauthorized IP", %{conn: conn} do
    conn = %{conn | remote_ip: {10, 0, 0, 1}}
    conn = AdminAuth.call(conn, AdminAuth.init([]))
    assert conn.halted
    assert conn.status == 403
  end
end
