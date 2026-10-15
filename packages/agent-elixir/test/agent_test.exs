defmodule ConvergerAgent.AgentTest do
  use ExUnit.Case, async: true

  alias ConvergerAgent.{
    Ack,
    CloseError,
    Error,
    FakeServer,
    HandlerError,
    Reply,
    Schemas,
    TestBot,
    Wire
  }

  @moduletag :capture_log

  @conv "c0a8012e-7d3b-4c5e-9f1a-2b3c4d5e6f70"
  @other "5b1d7c2a-0e4f-4a6b-9c8d-7e6f5a4b3c2d"

  defp welcome,
    do: %{
      "type" => "welcome",
      "data" => %{"protocol" => "converger/1", "scope" => "channel", "limits" => %{}}
    }

  defp user_turn(seq, text, conv \\ @conv) do
    %{
      "conversationId" => conv,
      "frame" => %{
        "type" => "text",
        "id" => "m-#{seq}",
        "seq" => seq,
        "from" => "user",
        "data" => %{"text" => text}
      }
    }
  end

  defp run_frame(status, conv \\ @conv),
    do: %{
      "conversationId" => conv,
      "frame" => %{"type" => "run", "data" => %{"status" => status}}
    }

  defp start_agent(handler, opts \\ []) do
    server = start_supervised!(FakeServer.child_spec(self()))
    test = self()

    opts =
      Keyword.merge(
        [
          url: FakeServer.url(server),
          token: "tok",
          handler: handler,
          on_error: &send(test, {:reported, &1}),
          backoff_initial: 5,
          backoff_max: 20
        ],
        opts
      )

    start_supervised!({ConvergerAgent, opts})
  end

  # Accepts the connection, reads hello and sends welcome.
  defp connect(token \\ "tok") do
    conn = Wire.accept(token)
    assert %{"type" => "hello"} = Wire.next(conn)
    Wire.write(conn, welcome())
    conn
  end

  test "the matcher and the schemas reject mismatches" do
    assert {:error, _} = Wire.match(%{"type" => "run"}, %{"type" => "run", "extra" => 1}, %{})
    assert {:error, _} = Wire.match(%{"id" => "{{x}}"}, %{"id" => "y"}, %{"x" => "z"})
    assert {:error, _} = Wire.match([1, 2], [1], %{})

    assert {:ok, %{"c" => "v"}} =
             Wire.match(%{"a" => "$capture:c", "b" => "$any"}, %{"a" => "v", "b" => 1}, %{})

    bad = %{"conversationId" => @conv, "frame" => %{"type" => "interrupt", "data" => %{}}}
    assert {:error, _} = Schemas.validate(bad)
    assert {:error, _} = Schemas.validate(%{"type" => "hello", "group" => ""})
    assert :ok = Schemas.validate(run_frame("started"))
  end

  test "socket_url/1 maps a server base URL to the native endpoint" do
    assert ConvergerAgent.socket_url("https://chat.example.com/") ==
             "wss://chat.example.com/socket/converger/v1"

    assert ConvergerAgent.socket_url("http://localhost:4000") ==
             "ws://localhost:4000/socket/converger/v1"
  end

  test "a second consecutive 4401 stops the agent; the token function runs on every connect" do
    counter = :counters.new(1, [])

    token = fn ->
      :counters.add(counter, 1, 1)
      "tok"
    end

    agent = start_agent(fn _, _ -> :ok end, token: token)
    ref = Process.monitor(agent)

    for _ <- 1..2 do
      conn = Wire.accept("tok")
      assert %{"type" => "hello"} = Wire.next(conn)

      Wire.write(conn, %{
        "type" => "error",
        "data" => %{"code" => "token_expired", "message" => "expired", "retryable" => true}
      })

      Wire.close(conn, 4401)
    end

    assert_receive {:DOWN, ^ref, :process, ^agent,
                    {:shutdown, {:closed, 4401, %Error{code: "token_expired"}}}},
                   5_000

    assert :counters.get(counter, 1) == 2

    assert_received {:reported,
                     %CloseError{code: 4401, last_error: %Error{code: "token_expired"}}}
  end

  test "4403 stops the agent" do
    agent = start_agent(fn _, _ -> :ok end)
    ref = Process.monitor(agent)
    conn = Wire.accept("tok")
    Wire.next(conn)
    Wire.close(conn, 4403)
    assert_receive {:DOWN, ^ref, :process, ^agent, {:shutdown, {:closed, 4403, nil}}}, 5_000
  end

  test "a raising handler ends its run with status error and is reported" do
    start_agent(fn _, _ -> raise "boom" end)
    conn = connect()
    Wire.write(conn, user_turn(1, "hi"))
    Wire.expect(conn, run_frame("started"))
    Wire.expect(conn, run_frame("error"))

    assert_receive {:reported,
                    %HandlerError{kind: :error, reason: %RuntimeError{}, conversation_id: @conv}},
                   2_000
  end

  test "a handler returning {:error, reason} ends its run with status error" do
    start_agent(fn _, _ -> {:error, :nope} end)
    conn = connect()
    Wire.write(conn, user_turn(1, "hi"))
    Wire.expect(conn, run_frame("started"))
    Wire.expect(conn, run_frame("error"))
    assert_receive {:reported, %HandlerError{kind: :error_tuple, reason: :nope}}, 2_000
  end

  test "two conversations run concurrently" do
    test = self()

    start_agent(fn turn, _reply ->
      send(test, {:started, turn.conversation_id, self()})
      receive do: (:release -> :ok)
    end)

    conn = connect()
    Wire.write(conn, user_turn(1, "a"))
    Wire.write(conn, user_turn(1, "b", @other))
    assert_receive {:started, a, pa}, 2_000
    assert_receive {:started, b, pb}, 2_000
    assert Enum.sort([a, b]) == Enum.sort([@conv, @other])
    send(pa, :release)
    send(pb, :release)
  end

  test "stopping the agent fails a waiting ask with :stopped" do
    test = self()

    agent =
      start_agent(fn _turn, reply ->
        result = Reply.ask(reply, %{"title" => "?"})
        send(test, {:ask, result})
        result
      end)

    conn = connect()
    Wire.write(conn, user_turn(1, "hi"))
    Wire.expect(conn, run_frame("started"))
    assert %{"frame" => %{"type" => "interrupt"}} = Wire.next(conn)
    assert :ok = ConvergerAgent.stop(agent, 5_000)
    assert_received {:ask, {:error, :stopped}}
    refute_received {:reported, %HandlerError{}}
  end

  test "an answer to an unknown interrupt is reported" do
    start_agent(fn _, _ -> :ok end)
    conn = connect()

    Wire.write(conn, %{
      "conversationId" => @conv,
      "frame" => %{"type" => "resume", "answers" => %{"ask/x#0" => "yes"}}
    })

    assert_receive {:reported, %Error{code: "unknown_interrupt", conversation_id: @conv}}, 2_000
  end

  test "a send without ack times out; watermarks follow the conversation" do
    test = self()

    agent =
      start_agent(
        fn _turn, reply -> send(test, {:sent, Reply.text(reply, "x")}) end,
        ack_timeout: 50,
        watermarks: %{@other => 3}
      )

    conn = connect()
    Wire.write(conn, user_turn(4, "hi"))
    Wire.expect(conn, run_frame("started"))

    Wire.expect(conn, %{
      "conversationId" => @conv,
      "frame" => %{"type" => "text", "clientId" => "$any", "data" => %{"text" => "x"}}
    })

    assert_receive {:sent, {:error, :timeout}}, 2_000
    assert ConvergerAgent.watermarks(agent) == %{@other => 3, @conv => 4}
  end

  test "frames written while disconnected are sent after the next welcome, typing is dropped" do
    test = self()

    start_agent(fn _turn, reply ->
      send(test, {:reply, self(), reply})
      receive do: (:go -> :ok)
      Reply.typing(reply, true)
      Reply.tool_call(reply, %{id: "t1", name: "n", status: "running", started_at: 1, error: nil})
      send(test, :written)
      send(test, {:ack, Reply.text(reply, "after")})
    end)

    conn = connect()
    Wire.write(conn, user_turn(1, "hi"))
    Wire.expect(conn, run_frame("started"))
    assert_receive {:reply, task, _reply}, 2_000
    Wire.close(conn, 1012)
    # wait for the agent to notice the close before the handler writes
    conn = Wire.accept("tok")
    assert %{"type" => "hello"} = Wire.next(conn)
    send(task, :go)
    assert_receive :written, 2_000
    Wire.write(conn, welcome())

    Wire.expect(conn, %{
      "conversationId" => @conv,
      "frame" => %{
        "type" => "tool_call",
        "data" => %{"id" => "t1", "name" => "n", "status" => "running", "startedAt" => 1}
      }
    })

    caps =
      Wire.expect(conn, %{
        "conversationId" => @conv,
        "frame" => %{"type" => "text", "clientId" => "$capture:c", "data" => %{"text" => "after"}}
      })

    Wire.write(conn, %{
      "conversationId" => @conv,
      "frame" => %{
        "type" => "ack",
        "clientId" => caps["c"],
        "id" => "m-2",
        "seq" => 2,
        "timestamp" => 5
      }
    })

    assert_receive {:ack, {:ok, %Ack{seq: 2, id: "m-2", duplicate: false}}}, 2_000
    Wire.expect(conn, run_frame("finished"))
  end

  test "use ConvergerAgent: child_spec/1 starts the module's handle_turn/2" do
    server = start_supervised!(FakeServer.child_spec(self()))
    spec = TestBot.child_spec(url: FakeServer.url(server), token: "tok", group: "workers")
    assert %{id: TestBot, restart: :transient} = spec
    start_supervised!(spec)

    conn = Wire.accept("tok")
    assert %{"type" => "hello", "group" => "workers"} = Wire.next(conn)
    Wire.write(conn, welcome())
    Wire.write(conn, user_turn(1, "hi"))
    Wire.expect(conn, run_frame("started"))

    Wire.expect(conn, %{
      "conversationId" => @conv,
      "frame" => %{"type" => "text", "clientId" => "$any", "data" => %{"text" => "bot: hi"}}
    })
  end
end
