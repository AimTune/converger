defmodule ConvergerAgent.FakeServer do
  @moduledoc false
  # An in-process stand-in for the native endpoint: a Bandit plug that
  # upgrades every request to ConvergerAgent.FakeSocket and hands each
  # accepted connection to the test process, which then drives it with
  # ConvergerAgent.Wire.

  @behaviour Plug

  @doc "A Bandit child spec on a free port; the test process receives the connections."
  def child_spec(test_pid) do
    Supervisor.child_spec(
      {Bandit, plug: {__MODULE__, test_pid}, ip: :loopback, port: 0, startup_log: false},
      id: __MODULE__
    )
  end

  @doc "The agent URL of a started server."
  def url(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "ws://127.0.0.1:#{port}/socket/converger/v1"
  end

  @impl true
  def init(test_pid), do: test_pid

  @impl true
  def call(conn, test_pid) do
    auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()

    conn
    |> Plug.Conn.put_resp_header("sec-websocket-protocol", "converger.v1")
    |> WebSockAdapter.upgrade(ConvergerAgent.FakeSocket, %{test: test_pid, auth: auth}, [])
    |> Plug.Conn.halt()
  end
end
