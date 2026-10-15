defmodule ConvergerWeb.HTTPAdvisoriesTest do
  # Guards the `ignore_advisories` entries for bandit / cowlib in mix.exs:
  # they are only safe while the affected code paths stay unreachable.
  use ExUnit.Case, async: true

  @h2_preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  defmodule OkPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  defp http_options do
    :converger
    |> Application.fetch_env!(ConvergerWeb.Endpoint)
    |> Keyword.fetch!(:http)
  end

  test "the endpoint does not serve HTTP/2 (EEF-CVE-2026-105659)" do
    assert http_options() |> Keyword.fetch!(:http_2_options) |> Keyword.fetch!(:enabled) == false

    bandit_options = Keyword.take(http_options(), [:http_2_options])

    {:ok, server} =
      Bandit.start_link(
        [plug: OkPlug, ip: :loopback, port: 0, startup_log: false] ++ bandit_options
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, @h2_preface)

    # An HTTP/2 server answers the preface with a SETTINGS frame (type 0x4);
    # with HTTP/2 off, Bandit treats it as a bad HTTP/1 request.
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, <<_length::24, 0x4, _rest::binary>>} ->
        flunk("the endpoint answered an HTTP/2 preface")

      {:ok, response} ->
        assert response =~ "HTTP/1.1"

      {:error, :closed} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  test "nothing builds structured headers with cowlib (EEF-CVE-2026-43966)" do
    offenders =
      for path <- Path.wildcard("{lib,config}/**/*.{ex,exs}"),
          source = File.read!(path),
          function <- [":cow_http_struct_hd", "wt_protocol"],
          String.contains?(source, function),
          do: {path, function}

    assert offenders == []
  end
end
