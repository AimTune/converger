defmodule ConvergerWeb.GRPC.ChannelStreamTest do
  @moduledoc """
  Protocol v1 over gRPC (`converger.v1.ChannelStream/Connect`, ADR-0056)
  end to end: the `grpc` library's client against the gRPC endpoint on a
  real port. Every server frame is mapped back to JSON and validated against
  the protocol's JSON Schema by `ConvergerWeb.GRPCClient`.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Repo}
  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias ConvergerWeb.GRPCClient, as: Client
  alias ConvergerWeb.ProtocolClient, as: WS

  @moduletag :protocol

  setup_all do
    %{port: Client.start_server()}
  end

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp token(channel, conversation, opts \\ []) do
    {:ok, token, _claims} =
      ConvergerToken.generate_conversation_token(channel, conversation.id, opts)

    token
  end

  defp activity!(conversation, text, sender \\ "bot-1") do
    {:ok, activity} =
      Activities.create_activity(%{
        "type" => "message",
        "text" => text,
        "sender" => sender,
        "tenant_id" => conversation.tenant_id,
        "conversation_id" => conversation.id
      })

    activity
  end

  defp put_limits(limits) do
    previous = Application.fetch_env!(:converger, :websocket)
    Application.put_env(:converger, :websocket, Keyword.merge(previous, limits))
    on_exit(fn -> Application.put_env(:converger, :websocket, previous) end)
  end

  # Connect with the token in the metadata and complete the handshake.
  defp join(ctx, token, hello \\ %{}) do
    client = Client.connect(ctx.port, token: token)
    on_exit(fn -> close(client) end)
    client = Client.push(client, Map.merge(%{"type" => "hello"}, hello))
    assert %{"type" => "welcome"} = welcome = Client.recv(client)
    {welcome, client}
  end

  # Cancels the stream and waits for its session to end, so it does not
  # outlive the test (and its database sandbox).
  defp close(client) do
    Client.cancel(client)
    wait_until(fn -> ConvergerWeb.ClientConnections.counts()[{"protocol", "grpc"}] == 0 end)
  end

  defp assert_closed(client, code, status) do
    assert {:close, ^code} = Client.recv(client)
    assert {:status, ^status} = Client.recv(client)
  end

  describe "handshake" do
    test "welcome describes the session and replays after the watermark", ctx do
      first = activity!(ctx.conversation, "one")
      activity!(ctx.conversation, "two")
      activity!(ctx.conversation, "three")

      {welcome, client} =
        join(ctx, token(ctx.channel, ctx.conversation, user_id: "alice"), %{
          "watermark" => first.seq
        })

      assert %{
               "protocol" => "converger/1",
               "conversationId" => conversation_id,
               "userId" => "alice",
               "watermark" => 3,
               "capabilities" => %{"acks" => true},
               "limits" => %{"maxFrameBytes" => _}
             } = welcome["data"]

      assert conversation_id == ctx.conversation.id
      assert %{"type" => "text", "seq" => 2, "data" => %{"text" => "two"}} = Client.recv(client)
      assert %{"type" => "text", "seq" => 3, "data" => %{"text" => "three"}} = Client.recv(client)
      Client.refute_frame(client)
    end

    test "the token may come from hello.token instead of the metadata", ctx do
      client = Client.connect(ctx.port)
      on_exit(fn -> close(client) end)

      client =
        Client.push(client, %{"type" => "hello", "token" => token(ctx.channel, ctx.conversation)})

      assert %{"type" => "welcome"} = Client.recv(client)
    end

    test "an invalid token draws unauthorized, close 4401 and UNAUTHENTICATED", ctx do
      client = Client.connect(ctx.port, token: "not-a-token")
      client = Client.push(client, %{"type" => "hello"})
      assert %{"type" => "error", "data" => %{"code" => "unauthorized"}} = Client.recv(client)
      assert_closed(client, 4401, :unauthenticated)
    end

    test "a missing credential is refused the same way", ctx do
      client = Client.connect(ctx.port) |> Client.push(%{"type" => "hello"})
      assert %{"data" => %{"code" => "unauthorized"}} = Client.recv(client)
      assert_closed(client, 4401, :unauthenticated)
    end

    test "frames before hello draw no_session", ctx do
      client = Client.connect(ctx.port, token: token(ctx.channel, ctx.conversation))
      on_exit(fn -> close(client) end)
      client = Client.push(client, %{"type" => "ping"})
      assert %{"data" => %{"code" => "no_session", "frameType" => "ping"}} = Client.recv(client)
    end
  end

  describe "sending" do
    test "a text frame with a clientId is persisted once and acked; a resend is a duplicate",
         ctx do
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation, user_id: "alice"))
      frame = %{"type" => "text", "clientId" => "c-1", "data" => %{"text" => "hi"}}

      client = Client.push(client, frame)
      ack = Client.recv_type(client, "ack")
      assert %{"clientId" => "c-1", "seq" => 1, "id" => id} = ack
      refute Map.has_key?(ack, "duplicate")

      client = Client.push(client, frame)
      assert %{"id" => ^id, "seq" => 1, "duplicate" => true} = Client.recv_type(client, "ack")

      # The same idempotency key as the WebSocket: a resend over either is recognised.
      assert [%Activity{text: "hi", sender: "alice", idempotency_key: "ws:alice:c-1"}] =
               Repo.all(Activity)
    end

    test "a turn sent over gRPC is routed to a WebSocket client of the conversation", ctx do
      ws_port = WS.start_server()

      {:ok, ws} =
        WS.connect(ws_port,
          headers: [
            {"authorization",
             "Bearer #{token(ctx.channel, ctx.conversation, user_id: "agent-7")}"}
          ]
        )

      ws = WS.push(ws, %{"type" => "hello"})
      {%{"type" => "welcome"}, ws} = WS.recv(ws)

      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation, user_id: "alice"))

      client =
        Client.push(client, %{
          "type" => "text",
          "clientId" => "c-9",
          "data" => %{"text" => "hello"}
        })

      assert %{"seq" => seq} = Client.recv_type(client, "ack")

      {at_ws, _ws} = WS.recv_type(ws, "text")
      assert %{"seq" => ^seq, "from" => "bot", "sender" => %{"id" => "alice"}} = at_ws
      assert at_ws["data"]["text"] == "hello"
    end

    test "a WebSocket client's turn and other activities arrive live, in order", ctx do
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation, user_id: "alice"))
      activity!(ctx.conversation, "one")
      activity!(ctx.conversation, "two")

      assert %{"seq" => 1, "data" => %{"text" => "one"}} = Client.recv_type(client, "text")
      assert %{"seq" => 2, "data" => %{"text" => "two"}} = Client.recv_type(client, "text")
    end

    test "validation errors draw invalid_message with details", ctx do
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation))
      long = String.duplicate("x", 70_000)

      client =
        Client.push(client, %{"type" => "text", "clientId" => "c-2", "data" => %{"text" => long}})

      assert %{"data" => %{"code" => code, "clientId" => "c-2"}} =
               Client.recv_type(client, "error")

      assert code in ["invalid_message", "payload_too_large"]
    end

    test "frames without a typed message travel as raw: bot frames draw bot_unavailable", ctx do
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation))
      client = Client.push(client, %{"type" => "abort"})

      assert %{"data" => %{"code" => "bot_unavailable", "frameType" => "abort"}} =
               Client.recv(client)
    end
  end

  describe "resume" do
    test "a client that reconnects with its watermark gets exactly what it missed", ctx do
      t = token(ctx.channel, ctx.conversation, user_id: "alice")
      {_welcome, client} = join(ctx, t)
      activity!(ctx.conversation, "one")
      assert %{"seq" => 1} = Client.recv_type(client, "text")

      # Disconnect, miss two activities, reconnect from the last seq seen.
      Client.cancel(client)
      activity!(ctx.conversation, "two")
      activity!(ctx.conversation, "three")

      {welcome, client} = join(ctx, t, %{"watermark" => 1})
      assert welcome["data"]["watermark"] == 3
      assert %{"seq" => 2, "data" => %{"text" => "two"}} = Client.recv(client)
      assert %{"seq" => 3, "data" => %{"text" => "three"}} = Client.recv(client)

      # Then live, with no gap and no duplicate.
      activity!(ctx.conversation, "four")
      assert %{"seq" => 4} = Client.recv_type(client, "text")
      Client.refute_frame(client)
    end

    test "sync replays after the given watermark", ctx do
      activity!(ctx.conversation, "one")
      activity!(ctx.conversation, "two")
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation), %{"watermark" => 2})
      client = Client.push(client, %{"type" => "sync", "watermark" => 1})
      assert %{"seq" => 2} = Client.recv(client)
    end

    test "ping is answered with heartbeat carrying the nonce", ctx do
      activity!(ctx.conversation, "one")
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation), %{"watermark" => 1})
      client = Client.push(client, %{"type" => "ping", "nonce" => "p-1"})
      assert %{"type" => "heartbeat", "nonce" => "p-1", "headSeq" => 1} = Client.recv(client)
    end
  end

  describe "signals" do
    test "typing is relayed between a gRPC and a WebSocket client", ctx do
      ws_port = WS.start_server()
      bob = token(ctx.channel, ctx.conversation, user_id: "bob")
      {:ok, ws} = WS.connect(ws_port, headers: [{"authorization", "Bearer #{bob}"}])
      ws = WS.push(ws, %{"type" => "hello"})
      {%{"type" => "welcome"}, ws} = WS.recv(ws)

      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation, user_id: "alice"))
      _client = Client.push(client, %{"type" => "typing", "isTyping" => true})

      {typing, _ws} = WS.recv_type(ws, "typing")
      assert %{"isTyping" => true, "sender" => %{"id" => "alice"}} = typing
    end
  end

  describe "endings, limits and draining" do
    setup do
      on_exit(&ConvergerWeb.Drain.reset/0)
    end

    test "a client half-close ends the stream with OK", ctx do
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation))
      Client.end_stream(client)
      assert_closed(client, 1000, :ok)
    end

    test "a cancelled stream ends the session", ctx do
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation))
      assert ConvergerWeb.ClientConnections.counts()[{"protocol", "grpc"}] == 1
      Client.cancel(client)

      wait_until(fn -> ConvergerWeb.ClientConnections.counts()[{"protocol", "grpc"}] == 0 end)
    end

    test "frames above maxFrameBytes draw payload_too_large and keep the stream", ctx do
      put_limits(max_frame_bytes: 64)
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation))

      client =
        Client.push(client, %{
          "type" => "text",
          "clientId" => "c-big",
          "data" => %{"text" => String.duplicate("x", 200)}
        })

      assert %{"data" => %{"code" => "payload_too_large"}} = Client.recv(client)
      client = Client.push(client, %{"type" => "ping"})
      assert %{"type" => "heartbeat"} = Client.recv(client)
    end

    # The client library logs the write it could not finish.
    @tag :capture_log
    test "a message above the hard cap ends the stream with RESOURCE_EXHAUSTED", ctx do
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation))
      cap = Application.fetch_env!(:converger, :websocket_max_frame_size)

      client =
        Client.push(client, %{
          "type" => "text",
          "data" => %{"text" => String.duplicate("x", cap + 1)}
        })

      assert_closed(client, 1009, :resource_exhausted)
    end

    test "frames above the per-connection rate draw rate_limited", ctx do
      put_limits(max_messages: 3, rate_window_ms: 60_000)
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation))

      client = Client.push(client, %{"type" => "ping"})
      assert %{"type" => "heartbeat"} = Client.recv(client)
      client = Client.push(client, %{"type" => "ping"})
      assert %{"type" => "heartbeat"} = Client.recv(client)
      client = Client.push(client, %{"type" => "ping"})

      assert %{"data" => %{"code" => "rate_limited", "retryAfterMs" => retry_after}} =
               Client.recv(client)

      assert retry_after > 0
    end

    test "a client that does not keep up is closed with 4503", ctx do
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation))
      put_limits(slow_consumer_queue_len: -1)
      activity!(ctx.conversation, "one")
      assert_closed(client, 4503, :resource_exhausted)
    end

    test "idle streams are closed with 4408 after heartbeats", ctx do
      Application.put_env(:converger, ConvergerWeb.Protocol,
        heartbeat_interval_ms: 1_000,
        idle_timeout_ms: 1_500
      )

      on_exit(fn -> Application.delete_env(:converger, ConvergerWeb.Protocol) end)

      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation))
      assert %{"type" => "heartbeat"} = Client.recv(client, 1_500)
      assert {:close, 4408} = recv_close(client)
      assert {:status, :deadline_exceeded} = Client.recv(client)
    end

    test "new streams are refused with UNAVAILABLE while the node drains", ctx do
      ConvergerWeb.Drain.start_draining()
      client = Client.connect(ctx.port, token: token(ctx.channel, ctx.conversation))
      client = Client.push(client, %{"type" => "hello"})
      assert {:status, :unavailable} = Client.recv(client)
    end

    test "draining closes open streams with 1012 and UNAVAILABLE", ctx do
      {_welcome, client} = join(ctx, token(ctx.channel, ctx.conversation))
      ConvergerWeb.ProtocolConnections.drain()
      assert_closed(client, 1012, :unavailable)
    end

    test "connections and frames are counted with transport grpc", ctx do
      handler = "grpc-telemetry-#{System.unique_integer()}"
      test = self()

      :telemetry.attach_many(
        handler,
        [[:converger, :ws, :connected], [:converger, :ws, :frame]],
        fn event, measurements, metadata, _ -> send(test, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {_welcome, _client} = join(ctx, token(ctx.channel, ctx.conversation))

      assert_receive {[:converger, :ws, :connected], _, %{socket: "protocol", transport: "grpc"}}

      assert_receive {[:converger, :ws, :frame], _,
                      %{socket: "protocol", transport: "grpc", direction: :in}}
    end
  end

  defp recv_close(client) do
    case Client.recv(client, 1_000) do
      %{"type" => "heartbeat"} -> recv_close(client)
      other -> other
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end
