defmodule Converger.ChativaCompatTest do
  @moduledoc """
  chativa is Converger's reference WebSocket client (#65, ADR-0065): its
  unmodified `@chativa/connector-mekik` must work against the native
  endpoint. This suite runs chativa's real `MekikConnector` and
  `parseChatFrame` (vendored in `fixtures/chativa`, see its README) in Node
  against a real Converger server over a real socket, and asserts what
  chativa's ChatEngine would receive: messages, quick replies, tool-call
  traces, GenUI chunks and typing. It also runs the REST history page
  (`format=frames`) through `parseChatFrame`.

  Needs `node` with TypeScript type stripping (Node >= 22.18) on PATH. The
  suite is skipped without it, unless `CHATIVA_COMPAT=required` (CI), where
  a missing Node fails the run.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ChativaHarness, only: [command: 2, await: 2, drain: 2, shown: 1]

  alias Converger.{Activities, Repo}
  alias Converger.Activities.{Activity, MessagePayload}
  alias Converger.Auth.ConvergerToken
  alias Converger.ChativaHarness
  alias ConvergerWeb.ProtocolClient, as: Client

  @moduletag :protocol
  @moduletag :chativa

  @fixtures ChativaHarness.fixtures()
  @harness ChativaHarness.harness()

  cond do
    node = ChativaHarness.node_executable() ->
      @node node

    System.get_env("CHATIVA_COMPAT") == "required" ->
      raise "CHATIVA_COMPAT=required but no node with TypeScript type stripping (>= 22.18) is on PATH"

    true ->
      @node nil
      @moduletag skip:
                   "chativa compatibility needs node >= 22.18 (TypeScript type stripping) on PATH"
  end

  # Converger frames chativa's connector-mekik would render as chat bubbles
  # (mekik/1 open rule), so a mekik/1 client must never receive them.
  @converger_only ~w(ack deliveryStatus presence heartbeat tokenRefreshed replayTruncated)

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    port = Client.start_server()
    %{tenant: tenant, channel: channel, conversation: conversation, port: port}
  end

  ## Helpers

  defp token(ctx, user_id) do
    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(ctx.channel, ctx.conversation.id,
        user_id: user_id
      )

    token
  end

  # A frame stored as a bot (the mekik relay, #64, will store bot frames this
  # way), or a plain end-user turn.
  defp store!(ctx, frame, sender) do
    params =
      case MessagePayload.from_frame(frame, keep_id: true) do
        :plain -> %{"text" => frame["data"]["text"]}
        {:ok, type, payload} -> %{"message_type" => type, "payload" => payload}
      end

    {:ok, activity} =
      params
      |> Map.merge(%{
        "type" => "message",
        "sender" => sender,
        "tenant_id" => ctx.tenant.id,
        "conversation_id" => ctx.conversation.id
      })
      |> Activities.create_activity()

    activity
  end

  # Starts chativa's MekikConnector, configured as docs/protocol/clients.md
  # describes: TokenAuth, the conversation id, routeInUrl, no subprotocol.
  defp start_chativa(ctx, token) do
    ChativaHarness.start(@node, %{
      url: "ws://127.0.0.1:#{ctx.port}/socket/converger/v1",
      token: token,
      conversationId: ctx.conversation.id,
      routeInUrl: true
    })
  end

  defp refute_converger_frames(events) do
    for %{"event" => "message", "message" => %{"type" => type} = message} <- events do
      refute type in @converger_only, "chativa rendered #{inspect(message)} as a message"
    end
  end

  defp recv_seq(client, seq) do
    case Client.recv_type(client, "text") do
      {%{"seq" => ^seq} = frame, client} -> {frame, client}
      {_older, client} -> recv_seq(client, seq)
    end
  end

  defp parse_frames(frames) do
    path = Path.join(System.tmp_dir!(), "chativa_frames_#{System.unique_integer([:positive])}")
    File.write!(path, Jason.encode!(frames))
    on_exit(fn -> File.rm(path) end)

    {out, 0} = System.cmd(@node, [@harness, "parse", path], cd: @fixtures)
    Jason.decode!(out)
  end

  ## The transcript a conversation replays

  @interrupt_id "approve/0:interrupt#0"

  @transcript [
    {%{"type" => "text", "data" => %{"text" => "Where is my order?"}}, "alice"},
    {%{
       "type" => "tool_call",
       "data" => %{
         "id" => "t1",
         "name" => "get_order",
         "status" => "running",
         "params" => %{"id" => "ORD-42"}
       }
     }, "mekik-bot"},
    {%{
       "type" => "tool_call",
       "data" => %{
         "id" => "t1",
         "name" => "get_order",
         "status" => "completed",
         "result" => %{"id" => "ORD-42", "total" => 249.9}
       }
     }, "mekik-bot"},
    {%{"type" => "text", "data" => %{"text" => "Your order shipped."}}, "mekik-bot"},
    {%{
       "type" => "text",
       "id" => "m-actions",
       "data" => %{"text" => "Track it?"},
       "actions" => [%{"label" => "Track", "value" => "/track ORD-42"}, %{"label" => "No thanks"}]
     }, "mekik-bot"},
    {%{
       "type" => "buttons",
       "id" => "m-buttons",
       "data" => %{
         "text" => "How can I help?",
         "buttons" => [
           %{"label" => "Track an order", "value" => "/track"},
           %{"label" => "Pricing", "url" => "https://example.com/pricing"}
         ]
       }
     }, "mekik-bot"},
    {%{
       "type" => "card",
       "id" => "card-ORD-42",
       "data" => %{
         "title" => "ORD-42",
         "subtitle" => "249.90 USD",
         "image" => "https://example.com/ord-42.png",
         "buttons" => [%{"label" => "Track", "value" => "/track ORD-42"}]
       }
     }, "mekik-bot"},
    {%{
       "type" => "image",
       "id" => "m-image",
       "data" => %{"src" => "https://example.com/receipt.png", "caption" => "Your receipt"}
     }, "mekik-bot"},
    {%{
       "type" => "genui",
       "streamId" => "stream-1",
       "done" => true,
       "chunk" => %{
         "type" => "ui",
         "component" => "order-card",
         "props" => %{"id" => "ORD-42"},
         "id" => 1
       }
     }, "mekik-bot"},
    {%{
       "type" => "interrupt",
       "id" => @interrupt_id,
       "data" => %{
         "payload" => %{"title" => "249.90 USD refund"},
         "actions" => [
           %{"label" => "Approve", "value" => %{"approved" => true}},
           %{"label" => "Reject", "value" => %{"approved" => false}}
         ]
       }
     }, "mekik-bot"},
    {%{
       "type" => "interrupt_resolved",
       "id" => @interrupt_id,
       "data" => %{"answer" => %{"approved" => true}}
     }, "mekik-bot"}
  ]

  defp store_transcript!(ctx) do
    for {frame, sender} <- @transcript, do: store!(ctx, frame, sender)
  end

  # The chativa view of the transcript, in order (ids and seqs checked too).
  defp assert_transcript(shown) do
    assert [
             %{
               "event" => "message",
               "message" => %{"type" => "text", "from" => "user", "seq" => 1} = user_turn
             },
             %{"event" => "toolCall", "toolCall" => %{"id" => "t1", "status" => "running"}},
             %{
               "event" => "toolCall",
               "toolCall" => %{
                 "id" => "t1",
                 "status" => "completed",
                 "result" => %{"total" => 249.9}
               }
             },
             %{
               "event" => "message",
               "message" => %{
                 "type" => "text",
                 "from" => "bot",
                 "data" => %{"text" => "Your order shipped."}
               }
             },
             %{"event" => "message", "message" => quick_reply},
             %{"event" => "message", "message" => buttons},
             %{"event" => "message", "message" => card},
             %{"event" => "message", "message" => image},
             %{"event" => "genui", "streamId" => "stream-1", "done" => true, "chunk" => chunk},
             %{"event" => "message", "message" => interrupt}
           ] = shown

    assert user_turn["data"] == %{"text" => "Where is my order?"}

    # parseChatFrame: a bot text frame with actions is a quick reply whose
    # chips stay after the tap.
    assert quick_reply == %{
             "id" => "m-actions",
             "type" => "quick-reply",
             "data" => %{
               "text" => "Track it?",
               "actions" => [
                 %{"label" => "Track", "value" => "/track ORD-42"},
                 %{"label" => "No thanks"}
               ],
               "keepActions" => true
             },
             "timestamp" => quick_reply["timestamp"]
           }

    assert is_integer(quick_reply["timestamp"])

    # Rich message types reach the renderer registry by name, data intact.
    assert %{"type" => "buttons", "id" => "m-buttons", "from" => "bot"} = buttons
    assert [%{"label" => "Track an order"}, %{"url" => _}] = buttons["data"]["buttons"]
    assert %{"type" => "card", "id" => "card-ORD-42", "data" => %{"title" => "ORD-42"}} = card
    assert %{"type" => "image", "data" => %{"src" => "https://example.com/receipt.png"}} = image

    assert chunk == %{
             "type" => "ui",
             "component" => "order-card",
             "props" => %{"id" => "ORD-42"},
             "id" => 1
           }

    # mekik/2 interrupt: rendered as chips from its actions; interrupt_resolved
    # renders nothing.
    assert %{
             "id" => "interrupt-" <> @interrupt_id,
             "type" => "quick-reply",
             "data" => %{
               "text" => "249.90 USD refund",
               "actions" => [%{"label" => "Approve"}, %{"label" => "Reject"}]
             }
           } = interrupt
  end

  ## Tests

  test "the replay reaches chativa as messages, quick replies, traces and GenUI", ctx do
    store_transcript!(ctx)
    {port, welcome, _} = start_chativa(ctx, token(ctx, "alice"))

    # welcome: connector-mekik adopts the identity and the head watermark.
    assert %{"conversationId" => conversation_id, "userId" => "alice", "watermark" => 11} =
             welcome["identity"]

    assert conversation_id == ctx.conversation.id

    {last, events} =
      await(port, &match?(%{"event" => "message", "message" => %{"id" => "interrupt-" <> _}}, &1))

    events = events ++ [last]
    rest = drain(port, 300)

    assert_transcript(shown(events))
    assert shown(rest) == [], "interrupt_resolved must render nothing: #{inspect(rest)}"
  end

  test "live frames, typing and a send round trip without Converger-only bubbles", ctx do
    {port, _welcome, _} = start_chativa(ctx, token(ctx, "alice"))

    # Another participant (an agent tab) on the full protocol.
    {:ok, agent} =
      Client.connect(ctx.port, headers: [{"authorization", "Bearer #{token(ctx, "agent-7")}"}])

    agent = Client.push(agent, %{"type" => "hello", "protocol" => "converger/1"})
    {%{"type" => "welcome"}, agent} = Client.recv(agent)

    # typing from the agent: chativa's flat `typing` frame.
    agent = Client.push(agent, %{"type" => "typing", "isTyping" => true})
    {_typing, _} = await(port, &(&1 == %{"event" => "typing", "isTyping" => true}))

    # A live bot message.
    store!(ctx, %{"type" => "text", "data" => %{"text" => "An agent joined."}}, "agent-7")

    {%{"message" => live}, _} =
      await(port, &match?(%{"event" => "message", "message" => %{"seq" => 1}}, &1))

    assert %{"type" => "text", "from" => "bot", "data" => %{"text" => "An agent joined."}} = live

    # chativa sends a turn the way ChatEngine does (createOutgoingMessage).
    command(port, %{
      cmd: "send",
      message: %{id: "1750000000000-abc1234", type: "text", data: %{text: "Thanks!"}}
    })

    {_sent, _} = await(port, &(&1 == %{"event" => "sent", "id" => "1750000000000-abc1234"}))

    # Persisted once, as alice, keyed by chativa's message id (v1 section 7);
    # the agent sees it.
    {frame, _agent} = recv_seq(agent, 2)
    assert %{"from" => "bot", "seq" => 2, "data" => %{"text" => "Thanks!"}} = frame

    assert %Activity{sender: "alice", idempotency_key: "ws:alice:1750000000000-abc1234"} =
             Repo.get_by!(Activity, conversation_id: ctx.conversation.id, seq: 2)

    # The ack and the delivery status of that send would be bubbles in
    # chativa: the mekik/1 profile does not send them.
    rest = drain(port, 500)
    refute_converger_frames(rest)
    assert shown(rest) == []
  end

  test "a heartbeat is a WebSocket ping, which keeps the idle connection open", ctx do
    Application.put_env(:converger, ConvergerWeb.Protocol,
      heartbeat_interval_ms: 1_000,
      idle_timeout_ms: 1_500
    )

    on_exit(fn -> Application.delete_env(:converger, ConvergerWeb.Protocol) end)

    {port, _welcome, _} = start_chativa(ctx, token(ctx, "alice"))

    # Three idle timeouts pass; Node answers the pings with pongs.
    events = drain(port, 4_500)
    refute Enum.any?(events, &(&1["event"] == "disconnected")), inspect(events)
    refute_converger_frames(events)
  end

  test "agent panel: a channel-scoped token lists conversations and switches between them",
       ctx do
    other = conversation_fixture(ctx.tenant, ctx.channel)
    store!(ctx, %{"type" => "text", "data" => %{"text" => "first customer"}}, "alice")

    store!(
      %{ctx | conversation: other},
      %{"type" => "text", "data" => %{"text" => "second"}},
      "bob"
    )

    # The agent console's backend mints a channel-scoped token.
    {:ok, agent_token, _} =
      ConvergerToken.generate_token(ctx.channel, scope: "channel", user_id: "agent-7")

    authed = fn -> put_req_header(build_conn(), "authorization", "Bearer #{agent_token}") end

    # listConversations
    %{"conversations" => listed} =
      authed.()
      |> get("/api/v1/converger/conversations")
      |> json_response(200)

    assert Enum.map(listed, & &1["lastMessage"]) |> Enum.sort() == ["first customer", "second"]

    # switchConversation: a conversation-bound token for each, then a socket.
    for %{"id" => id, "lastMessage" => text} <- listed do
      %{"token" => bound} =
        authed.() |> get("/api/v1/converger/conversations/#{id}") |> json_response(200)

      {port, welcome, _} =
        start_chativa(%{ctx | conversation: %{ctx.conversation | id: id}}, bound)

      assert welcome["identity"]["conversationId"] == id

      {%{"message" => message}, _} = await(port, &(&1["event"] == "message"))
      # The customer's turn is a bot-side bubble for the agent.
      assert %{"from" => "bot", "data" => %{"text" => ^text}} = message
      command(port, %{cmd: "exit"})
    end
  end

  test "REST history in frame format parses like the socket replay", %{conn: conn} = ctx do
    store_transcript!(ctx)

    page =
      conn
      |> put_req_header("authorization", "Bearer #{token(ctx, "alice")}")
      |> get(
        "/api/v1/converger/conversations/#{ctx.conversation.id}/activities?direction=backward&format=frames"
      )
      |> json_response(200)

    assert length(page["frames"]) == length(@transcript)
    kinds = page["frames"] |> parse_frames() |> Enum.map(& &1["kind"])

    # parseChatFrame covers the rich frames; message frames are "other" (the
    # connector renders them by type), interrupts are connector-mekik's own.
    assert kinds == [
             "other",
             "tool_call",
             "tool_call",
             "other",
             "quick_reply",
             "other",
             "other",
             "other",
             "genui",
             "other",
             "other"
           ]

    assert [%{"type" => "text", "from" => "user"} | _] = page["frames"]
  end

  test "typing and a user's own replayed turn follow parseChatFrame's rules" do
    assert [
             %{"kind" => "typing", "isTyping" => true},
             %{"kind" => "other"}
           ] =
             parse_frames([
               %{
                 "type" => "typing",
                 "isTyping" => true,
                 "from" => "bot",
                 "sender" => %{"id" => "agent-7", "role" => "agent"}
               },
               # A user's own text frame with actions is not offered again as chips.
               %{
                 "type" => "text",
                 "id" => "m-1",
                 "from" => "user",
                 "data" => %{"text" => "Track"},
                 "actions" => [%{"label" => "x"}]
               }
             ])
  end
end
