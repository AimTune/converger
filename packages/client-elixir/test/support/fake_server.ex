defmodule ConvergerClient.FakeServer do
  @moduledoc false
  # An in-process stand-in for the native endpoint: a Bandit plug that
  # upgrades to ConvergerClient.FakeSocket. State lives in an Agent.

  @behaviour Plug

  def start(frames \\ 0, opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          frames: Enum.map(1..frames//1, &text_frame(&1, "bot", "m#{&1}", nil)),
          hellos: [],
          received: [],
          subprotocols: [],
          close_after_replay: Keyword.get(opts, :close_after_replay, []),
          drop_first_text: Keyword.get(opts, :drop_first_text, false),
          acked: %{},
          conns: []
        }
      end)

    {:ok, server} =
      Bandit.start_link(plug: {__MODULE__, agent}, ip: :loopback, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {"ws://127.0.0.1:#{port}/socket/converger/v1", agent}
  end

  def text_frame(seq, from, text, client_id) do
    frame = %{
      "type" => "text",
      "id" => "a-#{seq}",
      "seq" => seq,
      "from" => from,
      "data" => %{"text" => text}
    }

    if client_id, do: Map.put(frame, "clientId", client_id), else: frame
  end

  def get(agent, key), do: Agent.get(agent, &Map.fetch!(&1, key))

  def push(agent, from, text) do
    {frame, conns} =
      Agent.get_and_update(agent, fn s ->
        frame = text_frame(length(s.frames) + 1, from, text, nil)
        {{frame, s.conns}, %{s | frames: s.frames ++ [frame]}}
      end)

    Enum.each(conns, &send(&1, {:push, frame}))
  end

  @impl true
  def init(agent), do: agent

  @impl true
  def call(conn, agent) do
    offered = Plug.Conn.get_req_header(conn, "sec-websocket-protocol")
    Agent.update(agent, &%{&1 | subprotocols: &1.subprotocols ++ offered})
    auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()

    conn
    |> Plug.Conn.put_resp_header("sec-websocket-protocol", "converger.v1")
    |> WebSockAdapter.upgrade(
      ConvergerClient.FakeSocket,
      %{agent: agent, auth: auth, hello: nil},
      []
    )
    |> Plug.Conn.halt()
  end
end
