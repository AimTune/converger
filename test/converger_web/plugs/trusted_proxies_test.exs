defmodule ConvergerWeb.Plugs.TrustedProxiesTest do
  # Not async: mutates application env.
  use ConvergerWeb.ConnCase, async: false

  alias ConvergerWeb.Plugs.{AdminAuth, TrustedProxies}

  setup do
    original_proxies = Application.get_env(:converger, :trusted_proxies)
    original_whitelist = Application.get_env(:converger, :admin_ip_whitelist)

    on_exit(fn ->
      Application.put_env(:converger, :trusted_proxies, original_proxies)
      Application.put_env(:converger, :admin_ip_whitelist, original_whitelist)
    end)

    Application.put_env(:converger, :trusted_proxies, ["10.0.0.0/8", "fd00::/8"])
    :ok
  end

  defp request(peer, xff \\ nil) do
    conn = %{build_conn() | remote_ip: peer}
    conn = if xff, do: put_req_header(conn, "x-forwarded-for", xff), else: conn
    TrustedProxies.call(conn, TrustedProxies.init([]))
  end

  test "honours X-Forwarded-For from a trusted proxy" do
    conn = request({10, 0, 0, 2}, "203.0.113.7")
    assert conn.remote_ip == {203, 0, 113, 7}
    assert conn.private[:peer_remote_ip] == {10, 0, 0, 2}
  end

  test "ignores X-Forwarded-For from an untrusted hop" do
    conn = request({198, 51, 100, 9}, "127.0.0.1")
    assert conn.remote_ip == {198, 51, 100, 9}
    refute Map.has_key?(conn.private, :peer_remote_ip)
  end

  test "ignores X-Forwarded-For when no proxies are configured" do
    Application.put_env(:converger, :trusted_proxies, [])
    assert request({10, 0, 0, 2}, "203.0.113.7").remote_ip == {10, 0, 0, 2}
  end

  test "skips chained trusted hops and ignores client-supplied entries to the left" do
    # Client spoofed "127.0.0.1"; the real client is 203.0.113.7, followed by trusted hops.
    conn = request({10, 0, 0, 2}, "127.0.0.1, 203.0.113.7, 10.1.1.1")
    assert conn.remote_ip == {203, 0, 113, 7}
  end

  test "a private address that is not a trusted proxy is treated as the client" do
    conn = request({10, 0, 0, 2}, "203.0.113.7, 192.168.5.5")
    assert conn.remote_ip == {192, 168, 5, 5}
  end

  test "stops at unparsable entries and keeps the last trusted hop" do
    conn = request({10, 0, 0, 2}, "203.0.113.7, garbage, 10.1.1.1")
    assert conn.remote_ip == {10, 1, 1, 1}
  end

  test "uses the left-most entry when every hop is trusted" do
    assert request({10, 0, 0, 2}, "10.9.9.9, 10.1.1.1").remote_ip == {10, 9, 9, 9}
  end

  test "keeps the peer when the header is missing" do
    assert request({10, 0, 0, 2}).remote_ip == {10, 0, 0, 2}
  end

  test "combines multiple X-Forwarded-For headers in order" do
    conn =
      %{build_conn() | remote_ip: {10, 0, 0, 2}}
      |> Map.update!(:req_headers, fn headers ->
        [{"x-forwarded-for", "203.0.113.7"}, {"x-forwarded-for", "10.1.1.1"} | headers]
      end)
      |> TrustedProxies.call(TrustedProxies.init([]))

    assert conn.remote_ip == {203, 0, 113, 7}
  end

  test "handles ports and IPv6 entries" do
    assert request({10, 0, 0, 2}, "203.0.113.7:4321").remote_ip == {203, 0, 113, 7}

    assert request({0xFD00, 0, 0, 0, 0, 0, 0, 1}, "[2001:db8::5]:443").remote_ip ==
             {0x2001, 0xDB8, 0, 0, 0, 0, 0, 5}

    assert request({10, 0, 0, 2}, "2001:db8::5").remote_ip == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 5}
  end

  test "spoofed header from an untrusted hop cannot pass the admin whitelist" do
    Application.put_env(:converger, :admin_ip_whitelist, ["127.0.0.1"])

    conn = request({198, 51, 100, 9}, "127.0.0.1") |> AdminAuth.call(AdminAuth.init([]))
    assert conn.halted
    assert conn.status == 403
  end

  test "admin whitelist sees the real client behind a trusted proxy" do
    Application.put_env(:converger, :admin_ip_whitelist, ["172.16.0.0/12"])

    conn = request({10, 0, 0, 2}, "172.20.1.1") |> AdminAuth.call(AdminAuth.init([]))
    refute conn.halted
  end

  test "is wired into the endpoint ahead of the router" do
    Application.put_env(:converger, :admin_ip_whitelist, ["203.0.113.7"])

    allowed =
      %{build_conn() | remote_ip: {10, 0, 0, 2}}
      |> put_req_header("x-forwarded-for", "203.0.113.7")
      |> get("/admin/login")

    assert allowed.remote_ip == {203, 0, 113, 7}
    assert allowed.status == 200

    denied =
      %{build_conn() | remote_ip: {198, 51, 100, 9}}
      |> put_req_header("x-forwarded-for", "203.0.113.7")
      |> get("/admin/login")

    assert denied.remote_ip == {198, 51, 100, 9}
    assert denied.status == 403
  end
end
