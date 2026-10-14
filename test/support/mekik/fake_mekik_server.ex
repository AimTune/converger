defmodule Converger.FakeMekikServer do
  @moduledoc """
  A scriptable mekik/1 server for the tests of the `mekik` channel adapter: a
  Bandit server on a random loopback port that upgrades every request to a
  WebSocket handled by `Converger.FakeMekikServer.Socket`.

  It keeps a per-conversation transcript like a mekik engine (mekik/1
  sections 1 and 2): `hello` (query string merged with the frame, frame
  wins) resolves the conversation (adopted only when it exists and belongs to
  the user, else minted), `welcome` carries the head `seq`, then every
  persistent frame above the asserted watermark is replayed. A user `text`
  is recorded (so a replay carries its echo) and answered by the scripted
  refund turn (`ORD-42`: `run started`, `tool_call` running and completed,
  an approval `interrupt`, `run interrupted`), any other text by
  `echo: <text>`. A `resume` answering the interrupt draws
  `interrupt_resolved`, the reply `text` and `run finished`.

  Options: `:token` (connections must present it, else `error unauthorized`
  and close 4401), `:greeting` (a bot text sent on a fresh conversation),
  `:genui` (the refund turn also sends a GenUI chunk and a text, see
  `refund_turn/1`).

  Every connection reports `{:mekik_connected, socket, params}` (the merged
  hello) and every client frame `{:mekik_frame, socket, frame}` to the test
  process.
  """

  @behaviour Plug

  def start_link(test, opts \\ []) do
    {:ok, state} =
      Agent.start(fn ->
        %{settings: Map.new(opts), conversations: %{}, sockets: %{}, minted: 0}
      end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, test: test, state: state},
        scheme: :http,
        ip: :loopback,
        port: 0,
        startup_log: false
      )

    # Unlinked: stopped by the test (stop/1) after the connections that use it.
    Process.unlink(server)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{server: server, port: port, state: state, url: "ws://127.0.0.1:#{port}/ws"}}
  end

  @doc """
  The bot's frames of the scripted refund turn (the answer to `ORD-42`), in
  order, without `seq`: `run started`, `tool_call` running and completed,
  with `genui: true` a GenUI order card and a `text`, the approval
  `interrupt` (id `int-1`) and `run interrupted`. `run` is transient, the rest
  persistent. A channel-scoped agent can send the same frames (Mode B).
  """
  def refund_turn(opts \\ []) do
    rich =
      if opts[:genui] do
        [
          %{
            "type" => "genui",
            "streamId" => "order-ORD-42",
            "chunk" => %{
              "type" => "ui",
              "component" => "order-card",
              "props" => %{"id" => "ORD-42", "total" => 249.9},
              "id" => 1
            },
            "done" => true
          },
          %{
            "type" => "text",
            "id" => "msg-order",
            "from" => "bot",
            "data" => %{"text" => "ORD-42 was delivered damaged."}
          }
        ]
      else
        []
      end

    [
      run("started"),
      %{
        "type" => "tool_call",
        "data" => %{
          "id" => "tool-1",
          "name" => "get_order",
          "status" => "running",
          "params" => %{"id" => "ORD-42"}
        }
      },
      %{
        "type" => "tool_call",
        "data" => %{
          "id" => "tool-1",
          "name" => "get_order",
          "status" => "completed",
          "params" => %{"id" => "ORD-42"},
          "result" => %{"id" => "ORD-42", "total" => 249.9}
        }
      }
    ] ++
      rich ++
      [
        %{
          "type" => "interrupt",
          "id" => "int-1",
          "data" => %{
            "payload" => %{"title" => "Refund $249.9 for ORD-42?"},
            "ui" => %{"component" => "approval-form", "props" => %{"orderId" => "ORD-42"}},
            "actions" => [
              %{"label" => "Approve", "value" => %{"approved" => true}},
              %{"label" => "Reject", "value" => %{"approved" => false}}
            ]
          }
        },
        run("interrupted")
      ]
  end

  @doc """
  The bot's frames answering a `resume` of the refund interrupt with `answer`:
  `run started`, `interrupt_resolved`, the reply `text`, `run finished`.
  """
  def refund_reply(answer) do
    reply =
      if answer == %{"approved" => true}, do: "Refund complete: ORD-42", else: "Refund declined."

    [
      run("started"),
      %{"type" => "interrupt_resolved", "id" => "int-1", "data" => %{"answer" => answer}},
      %{"type" => "text", "id" => "msg-reply", "from" => "bot", "data" => %{"text" => reply}},
      run("finished")
    ]
  end

  defp run(status), do: %{"type" => "run", "data" => %{"status" => status}}

  @doc "Stop the server and its state."
  def stop(server) do
    for pid <- [server.server, server.state], Process.alive?(pid) do
      try do
        if pid == server.state, do: Agent.stop(pid), else: Supervisor.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc "Stop accepting connections (the listener goes away), keeping the state."
  def stop_listener(server) do
    Supervisor.stop(server.server, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc "The transcript (persistent frames) of a mekik conversation."
  def transcript(server, conversation_id),
    do: Agent.get(server.state, &get_in(&1, [:conversations, conversation_id, :frames])) || []

  @doc "The ids of the conversations the server minted."
  def conversations(server), do: Agent.get(server.state, &Map.keys(&1.conversations))

  @doc """
  Append a persistent bot frame to a conversation's transcript (stamped with
  the next `seq`) and push it to its live connection, unless `push: false`.
  """
  def emit(server, conversation_id, frame, opts \\ []) do
    {frame, socket} =
      Agent.get_and_update(server.state, fn state -> record(state, conversation_id, frame) end)

    if socket && Keyword.get(opts, :push, true), do: push(socket, frame)
    frame
  end

  @doc "Push a frame to a socket."
  def push(socket, frame), do: send(socket, {:push, Jason.encode!(frame)})

  @doc "Close a socket with `code`."
  def close(socket, code, reason \\ ""), do: send(socket, {:close, code, reason})

  @doc "Forget every conversation (a mekik restart with an in-memory store)."
  def reset(server), do: Agent.update(server.state, &%{&1 | conversations: %{}})

  @doc false
  def record(state, conversation_id, frame) do
    conversation = Map.fetch!(state.conversations, conversation_id)
    seq = conversation.seq + 1
    frame = Map.put(frame, "seq", seq)
    conversation = %{conversation | seq: seq, frames: conversation.frames ++ [frame]}
    state = put_in(state, [:conversations, conversation_id], conversation)
    {{frame, Map.get(state.sockets, conversation_id)}, state}
  end

  @doc false
  def connect(server_state, socket, hello) do
    Agent.get_and_update(server_state, fn state ->
      user_id = hello["userId"] || "user-anon"
      requested = hello["conversationId"]

      {conversation_id, reset?, state} =
        case get_in(state, [:conversations, requested]) do
          %{user_id: ^user_id} ->
            {requested, false, state}

          _ ->
            minted = state.minted + 1
            id = "conv-#{minted}"
            conversation = %{user_id: user_id, seq: 0, frames: []}

            state =
              %{state | minted: minted}
              |> put_in([:conversations, id], conversation)

            {id, requested != nil, state}
        end

      state = put_in(state, [:sockets, conversation_id], socket)
      conversation = state.conversations[conversation_id]
      watermark = if reset?, do: 0, else: hello["watermark"] || 0

      welcome = %{
        "type" => "welcome",
        "data" => %{
          "protocol" => "mekik/1",
          "conversationId" => conversation_id,
          "userId" => user_id,
          "connectionId" => "connection-test",
          "watermark" => conversation.seq,
          "pending" => []
        }
      }

      replay = Enum.filter(conversation.frames, &(&1["seq"] > watermark))
      {{conversation_id, welcome, replay, conversation.seq == 0, state.settings}, state}
    end)
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    auth =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> token
        _ -> nil
      end

    WebSockAdapter.upgrade(
      conn,
      Converger.FakeMekikServer.Socket,
      %{test: opts[:test], state: opts[:state], query: conn.query_params, bearer: auth},
      timeout: 120_000
    )
  end
end
