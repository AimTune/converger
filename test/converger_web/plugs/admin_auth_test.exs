defmodule ConvergerWeb.Plugs.AdminAuthTest do
  # Not async: mutates application env.
  use ConvergerWeb.ConnCase, async: false

  alias ConvergerWeb.Plugs.AdminAuth

  setup do
    original = Application.get_env(:converger, :admin_ip_whitelist)
    on_exit(fn -> Application.put_env(:converger, :admin_ip_whitelist, original) end)
    :ok
  end

  defp call_with(conn, ip) do
    %{conn | remote_ip: ip} |> AdminAuth.call(AdminAuth.init([]))
  end

  test "permits allowed IP", %{conn: conn} do
    refute call_with(conn, {127, 0, 0, 1}).halted
  end

  test "blocks unauthorized IP", %{conn: conn} do
    conn = call_with(conn, {10, 0, 0, 1})
    assert conn.halted
    assert conn.status == 403
  end

  test "supports IPv4 CIDR ranges", %{conn: conn} do
    Application.put_env(:converger, :admin_ip_whitelist, ["10.0.0.0/8"])

    refute call_with(conn, {10, 0, 0, 1}).halted
    refute call_with(conn, {10, 255, 3, 7}).halted
    assert call_with(conn, {11, 0, 0, 1}).halted
    assert call_with(conn, {127, 0, 0, 1}).halted
  end

  test "supports IPv6 CIDR ranges and mixed entries", %{conn: conn} do
    Application.put_env(:converger, :admin_ip_whitelist, ["192.168.1.10", "fd00::/8"])

    refute call_with(conn, {192, 168, 1, 10}).halted
    assert call_with(conn, {192, 168, 1, 11}).halted
    refute call_with(conn, {0xFD12, 0, 0, 0, 0, 0, 0, 1}).halted
    assert call_with(conn, {0xFE80, 0, 0, 0, 0, 0, 0, 1}).halted
  end

  test "matches IPv4-mapped IPv6 peers against IPv4 entries", %{conn: conn} do
    Application.put_env(:converger, :admin_ip_whitelist, ["10.0.0.0/8"])

    refute call_with(conn, {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}).halted
  end

  @tag capture_log: true
  test "ignores invalid entries without crashing", %{conn: conn} do
    Application.put_env(:converger, :admin_ip_whitelist, ["not-an-ip", "10.0.0.0/99", "1.2.3.4"])

    refute call_with(conn, {1, 2, 3, 4}).halted
    assert call_with(conn, {10, 0, 0, 1}).halted
  end
end
