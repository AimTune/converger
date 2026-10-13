defmodule Converger.FakeDiscordGateway do
  @moduledoc """
  A scriptable Discord Gateway for the tests of
  `Converger.Channels.Discord.Gateway`: a Bandit server on a random loopback
  port that upgrades every request to a WebSocket handled by
  `Converger.FakeDiscordGateway.Socket`.

  Each connection reports `{:gateway_connected, socket, request_path}` and
  every payload the client sends as `{:gateway_frame, socket, payload}` to the
  test process; the test sends payloads with `push/2` and closes with
  `close/3`. The `HELLO` heartbeat interval is the `:heartbeat_interval`
  option (default 45 000 ms); heartbeats are acknowledged unless
  `:ack_heartbeats` is false (`set/3`).
  """

  @behaviour Plug

  def start_link(test, opts \\ []) do
    {:ok, settings} = Agent.start_link(fn -> Map.new(opts) end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, test: test, settings: settings},
        scheme: :http,
        ip: :loopback,
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{server: server, port: port, settings: settings, url: "ws://127.0.0.1:#{port}"}}
  end

  def set(gateway, key, value), do: Agent.update(gateway.settings, &Map.put(&1, key, value))

  def push(socket, payload), do: send(socket, {:push, Jason.encode!(payload)})

  def close(socket, code, reason \\ ""), do: send(socket, {:close, code, reason})

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    path =
      conn.request_path <> if(conn.query_string != "", do: "?" <> conn.query_string, else: "")

    WebSockAdapter.upgrade(
      conn,
      Converger.FakeDiscordGateway.Socket,
      %{test: opts[:test], settings: opts[:settings], path: path},
      timeout: 120_000
    )
  end
end
