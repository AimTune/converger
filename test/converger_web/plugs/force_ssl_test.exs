defmodule ConvergerWeb.Plugs.ForceSSLTest do
  # Not async: mutates application env (:force_ssl, :trusted_proxies).
  use ConvergerWeb.ConnCase, async: false

  alias ConvergerWeb.Plugs.{ForceSSL, TrustedProxies}

  @config [hsts: true, expires: 31_536_000, subdomains: false, preload: false]

  setup do
    original_force_ssl = Application.get_env(:converger, :force_ssl)
    original_proxies = Application.get_env(:converger, :trusted_proxies)

    on_exit(fn ->
      Application.put_env(:converger, :force_ssl, original_force_ssl)
      Application.put_env(:converger, :trusted_proxies, original_proxies)
    end)

    Application.put_env(:converger, :trusted_proxies, ["10.0.0.0/8"])
    :ok
  end

  defp request(peer, opts) do
    conn =
      Phoenix.ConnTest.build_conn(:get, "http://www.example.com/api/v1/x?a=1")
      |> Map.put(:remote_ip, peer)

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, acc ->
        put_req_header(acc, k, v)
      end)

    conn
    |> TrustedProxies.call(TrustedProxies.init([]))
    |> ForceSSL.call(ForceSSL.init(Keyword.take(opts, [:config])))
  end

  test "is a no-op when disabled" do
    conn = request({203, 0, 113, 7}, config: false)
    refute conn.halted
    assert get_resp_header(conn, "strict-transport-security") == []
  end

  test "redirects plain HTTP to HTTPS on the endpoint host" do
    conn = request({203, 0, 113, 7}, config: @config)

    assert conn.halted
    assert conn.status == 301
    assert [location] = get_resp_header(conn, "location")
    assert location == "https://#{ConvergerWeb.Endpoint.host()}/api/v1/x?a=1"
  end

  test "honours X-Forwarded-Proto from a trusted proxy and sets HSTS" do
    conn =
      request({10, 0, 0, 2},
        config: @config,
        headers: [{"x-forwarded-proto", "https"}, {"x-forwarded-for", "203.0.113.7"}]
      )

    refute conn.halted
    assert conn.scheme == :https

    assert get_resp_header(conn, "strict-transport-security") == [
             "max-age=31536000"
           ]
  end

  test "ignores X-Forwarded-Proto from an untrusted client" do
    conn =
      request({203, 0, 113, 7}, config: @config, headers: [{"x-forwarded-proto", "https"}])

    assert conn.halted
    assert conn.status == 301
    assert get_resp_header(conn, "strict-transport-security") == []
  end

  test "HSTS options are applied" do
    config = [hsts: true, expires: 600, subdomains: true, preload: true]

    conn =
      request({10, 0, 0, 2}, config: config, headers: [{"x-forwarded-proto", "https"}])

    assert get_resp_header(conn, "strict-transport-security") == [
             "max-age=600; preload; includeSubDomains"
           ]
  end

  test "excluded paths are not redirected" do
    conn = request({203, 0, 113, 7}, config: @config ++ [exclude: [paths: ["/api/v1/x"]]])
    refute conn.halted
  end

  test "reads the configuration at runtime through the endpoint" do
    Application.put_env(:converger, :force_ssl, @config)

    conn = get(%{build_conn() | remote_ip: {203, 0, 113, 7}}, "/admin/login")
    assert conn.status == 301
    assert ["https://" <> _] = get_resp_header(conn, "location")

    Application.put_env(:converger, :force_ssl, false)
    conn = get(%{build_conn() | remote_ip: {203, 0, 113, 7}}, "/admin/login")
    refute conn.status == 301
  end
end
