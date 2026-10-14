defmodule ConvergerWeb.ProtocolChannelSessionTest do
  @moduledoc """
  Channel-scoped connections on the native endpoint (docs/protocol/v1.md,
  section 10) and the bot relay (section 9), over a real socket: an end user
  on a `websocket` widget channel, an agent on a `websocket` bot channel that a
  routing rule targets from the widget. Every server frame is validated
  against the v1 schemas (bare or enveloped) by `ConvergerWeb.ProtocolClient`.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, RoutingRules}
  alias Converger.Auth.ConvergerToken
  alias ConvergerWeb.ProtocolClient, as: Client

  @moduletag :protocol

  setup do
    tenant = tenant_fixture()
    widget = channel_fixture(tenant)
    bot = channel_fixture(tenant)

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "widget to bot",
        tenant_id: tenant.id,
        source_channel_id: widget.id,
        target_channel_ids: [bot.id]
      })

    conversation = conversation_fixture(tenant, widget)
    port = Client.start_server()

    %{tenant: tenant, widget: widget, bot: bot, conversation: conversation, port: port}
  end

  defp open(port, token, hello \\ %{}) do
    {:ok, client} = Client.connect(port, headers: [{"authorization", "Bearer #{token}"}])
    client = Client.push(client, Map.merge(%{"type" => "hello"}, hello))
    {welcome, client} = Client.recv(client)
    assert %{"type" => "welcome"} = welcome
    {welcome, client}
  end

  defp agent(ctx, hello \\ %{}, opts \\ []) do
    {:ok, token, _} = ConvergerToken.generate_token(ctx.bot, [scope: "channel"] ++ opts)
    open(ctx.port, token, hello)
  end

  defp user(ctx) do
    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(ctx.widget, ctx.conversation.id,
        user_id: "alice"
      )

    open(ctx.port, token)
  end

  defp envelope(conversation, frame), do: %{"conversationId" => conversation.id, "frame" => frame}

  # The next enveloped frame of `type` for any conversation (others dropped).
  defp recv_enveloped(client, type, timeout \\ 2_000) do
    case Client.recv(client, timeout) do
      {%{"conversationId" => id, "frame" => %{"type" => ^type} = frame}, client} ->
        {id, frame, client}

      {%{}, client} ->
        recv_enveloped(client, type, timeout)

      {other, _client} ->
        flunk("expected an enveloped #{type}, got #{inspect(other)}")
    end
  end

  defp activity!(conversation, attrs) do
    {:ok, activity} =
      %{
        "type" => "message",
        "sender" => "alice",
        "tenant_id" => conversation.tenant_id,
        "conversation_id" => conversation.id
      }
      |> Map.merge(attrs)
      |> Activities.create_activity()

    activity
  end

  describe "handshake" do
    test "a channel token gets a channel welcome", ctx do
      {welcome, _client} = agent(ctx)

      assert %{"scope" => "channel", "channelId" => channel_id, "limits" => limits} =
               welcome["data"]

      assert channel_id == ctx.bot.id
      assert limits["maxConversations"] == 5_000
      refute Map.has_key?(welcome["data"], "conversationId")
    end

    test "hello.watermarks replays a routed conversation enveloped, from the agent's view", ctx do
      activity!(ctx.conversation, %{"text" => "one", "source_channel_id" => ctx.widget.id})
      activity!(ctx.conversation, %{"text" => "two", "source_channel_id" => ctx.widget.id})

      {_welcome, client} = agent(ctx, %{"watermarks" => %{ctx.conversation.id => 1}})

      assert {id, %{"seq" => 2, "from" => "user", "data" => %{"text" => "two"}}, _} =
               recv_enveloped(client, "text")

      assert id == ctx.conversation.id
    end

    test "a channel token of a non-websocket channel is refused", ctx do
      webhook = webhook_channel_fixture(ctx.tenant)
      {:ok, token, _} = ConvergerToken.generate_token(webhook, scope: "channel")
      {:ok, client} = Client.connect(ctx.port, headers: [{"authorization", "Bearer #{token}"}])
      client = Client.push(client, %{"type" => "hello"})
      assert {%{"data" => %{"code" => "forbidden"}}, client} = Client.recv(client)
      assert {{:close, 4403}, _} = Client.recv(client)
    end
  end

  describe "agent and end user" do
    test "a user turn reaches the agent; the agent's reply reaches the user", ctx do
      {_welcome, agent} = agent(ctx)
      {_welcome, user} = user(ctx)

      user =
        Client.push(user, %{"type" => "text", "clientId" => "u-1", "data" => %{"text" => "hi"}})

      assert {%{"type" => "ack"}, user} = Client.recv(user)

      {id, frame, agent} = recv_enveloped(agent, "text")
      assert id == ctx.conversation.id
      assert %{"from" => "user", "data" => %{"text" => "hi"}} = frame

      reply = %{
        "type" => "buttons",
        "clientId" => "a-1",
        "data" => %{"text" => "Pick", "buttons" => [%{"label" => "Track", "value" => "/track"}]}
      }

      agent = Client.push(agent, envelope(ctx.conversation, reply))
      {^id, %{"clientId" => "a-1", "seq" => seq}, _agent} = recv_enveloped(agent, "ack")

      {frame, _user} = Client.recv_type(user, "buttons")
      assert %{"seq" => ^seq, "from" => "bot", "data" => %{"text" => "Pick"}} = frame
    end

    test "mekik-native frames are stored; transient ones are relayed", ctx do
      {_welcome, agent} = agent(ctx)
      {_welcome, user} = user(ctx)

      tool = %{
        "type" => "tool_call",
        "data" => %{"id" => "t1", "name" => "lookup", "status" => "running"}
      }

      agent =
        Client.push(
          agent,
          envelope(ctx.conversation, %{"type" => "run", "data" => %{"status" => "started"}})
        )

      _agent = Client.push(agent, envelope(ctx.conversation, tool))

      assert {%{"type" => "run", "data" => %{"status" => "started"}}, user} = Client.recv(user)
      {frame, _user} = Client.recv_type(user, "tool_call")
      assert frame == Map.put(tool, "seq", frame["seq"])

      assert [%{message_type: "tool_call"}] =
               Activities.list_activities_since(ctx.conversation.id, nil)
    end

    test "the agent's typing reaches the user as from bot, role agent", ctx do
      {_welcome, agent} = agent(ctx, %{}, user_id: "agent-7")
      {_welcome, user} = user(ctx)

      _agent =
        Client.push(agent, envelope(ctx.conversation, %{"type" => "typing", "isTyping" => true}))

      {frame, _user} = Client.recv_type(user, "typing")
      assert %{"from" => "bot", "sender" => %{"id" => "agent-7", "role" => "agent"}} = frame
    end

    test "a mekik message id is kept and makes the send idempotent per conversation", ctx do
      {_welcome, agent} = agent(ctx)
      other = conversation_fixture(ctx.tenant, ctx.widget)

      text = %{"type" => "text", "id" => "msg-1", "data" => %{"text" => "Done."}}
      agent = Client.push(agent, envelope(ctx.conversation, text))
      {_, %{"clientId" => "msg-1", "seq" => 1}, agent} = recv_enveloped(agent, "ack")
      agent = Client.push(agent, envelope(ctx.conversation, text))
      {_, %{"duplicate" => true}, agent} = recv_enveloped(agent, "ack")
      agent = Client.push(agent, envelope(other, text))
      {id, ack, _agent} = recv_enveloped(agent, "ack")
      assert id == other.id and is_nil(ack["duplicate"])

      [stored] = Activities.list_activities_since(ctx.conversation.id, nil)
      assert stored.payload["id"] == "msg-1" and stored.source_channel_id == ctx.bot.id
    end
  end

  describe "bot relay (section 9)" do
    test "bot-only frames go to the agent, or draw bot_unavailable without one", ctx do
      {_welcome, user} = user(ctx)
      resume = %{"type" => "resume", "answers" => %{"i#0" => true}}

      user = Client.push(user, resume)
      assert {%{"data" => %{"code" => "bot_unavailable"}}, user} = Client.recv(user)

      {_welcome, agent} = agent(ctx)
      _user = Client.push(user, resume)
      {id, frame, _agent} = recv_enveloped(agent, "resume")
      assert id == ctx.conversation.id and frame == resume
    end

    test "a user turn answering an open interrupt reaches the agent as resume", ctx do
      {_welcome, agent} = agent(ctx)
      {_welcome, user} = user(ctx)

      interrupt = %{
        "type" => "interrupt",
        "id" => "approve#0",
        "data" => %{
          "payload" => %{"title" => "Refund?"},
          "actions" => [%{"label" => "Yes", "value" => %{"ok" => true}}]
        }
      }

      _agent = Client.push(agent, envelope(ctx.conversation, interrupt))
      {frame, user} = Client.recv_type(user, "interrupt")
      [stored] = Activities.list_activities_since(ctx.conversation.id, nil)

      _user =
        Client.push(user, %{
          "type" => "text",
          "data" => %{"text" => "Yes"},
          "replyTo" => %{"id" => stored.id, "seq" => frame["seq"]},
          "metadata" => %{
            "action" => %{"label" => "Yes", "value" => %{"ok" => true}, "source" => "web"}
          }
        })

      {_id, resume, _agent} = recv_enveloped(agent, "resume")
      assert resume == %{"type" => "resume", "answers" => %{"approve#0" => %{"ok" => true}}}
    end

    test "interrupt and interrupt_resolved share an id; a replyTo {seq} answers the interrupt",
         ctx do
      {_welcome, agent} = agent(ctx)
      {_welcome, user} = user(ctx)

      interrupt = %{
        "type" => "interrupt",
        "id" => "i1",
        "data" => %{
          "payload" => %{"title" => "Go?"},
          "actions" => [%{"label" => "Yes", "value" => "yes"}]
        }
      }

      agent = Client.push(agent, envelope(ctx.conversation, interrupt))
      {frame, user} = Client.recv_type(user, "interrupt")

      _user =
        Client.push(user, %{
          "type" => "text",
          "data" => %{"text" => "Yes"},
          "replyTo" => %{"seq" => frame["seq"]},
          "metadata" => %{"action" => %{"label" => "Yes", "value" => "yes", "source" => "web"}}
        })

      {_id, resume, agent} = recv_enveloped(agent, "resume")
      assert resume["answers"] == %{"i1" => "yes"}

      _agent =
        Client.push(
          agent,
          envelope(ctx.conversation, %{
            "type" => "interrupt_resolved",
            "id" => "i1",
            "data" => %{"answer" => "yes"}
          })
        )

      Process.sleep(200)

      types =
        ctx.conversation.id
        |> Activities.list_activities_since(nil)
        |> Enum.map(& &1.message_type)

      assert types == ["interrupt", nil, "interrupt_resolved"]
    end

    test "a user turn's meta reaches the agent with the turn", ctx do
      {_welcome, agent} = agent(ctx)
      {_welcome, user} = user(ctx)

      _user =
        Client.push(user, %{
          "type" => "text",
          "data" => %{"text" => "hi"},
          "meta" => %{"locale" => "tr-TR"}
        })

      {_id, frame, _agent} = recv_enveloped(agent, "text")
      assert frame["meta"] == %{"locale" => "tr-TR"}
    end
  end

  describe "envelopes and limits" do
    test "bare conversation frames and foreign conversations are refused", ctx do
      {_welcome, agent} = agent(ctx)

      agent = Client.push(agent, %{"type" => "text", "data" => %{"text" => "x"}})

      assert {%{"type" => "error", "data" => %{"code" => "bad_request"}}, agent} =
               Client.recv(agent)

      foreign = conversation_fixture(ctx.tenant, webhook_channel_fixture(ctx.tenant))

      agent =
        Client.push(agent, envelope(foreign, %{"type" => "text", "data" => %{"text" => "x"}}))

      {_id, %{"data" => %{"code" => "conversation_not_found"}}, agent} =
        recv_enveloped(agent, "error")

      agent =
        Client.push(
          agent,
          envelope(ctx.conversation, %{"type" => "resume", "answers" => %{"a" => 1}})
        )

      {_id, %{"data" => %{"code" => "bad_request"}}, _agent} = recv_enveloped(agent, "error")
    end

    test "following more than maxConversations evicts the least recently active", ctx do
      previous = Application.get_env(:converger, ConvergerWeb.Protocol, [])

      Application.put_env(
        :converger,
        ConvergerWeb.Protocol,
        Keyword.put(previous, :max_conversations, 1)
      )

      on_exit(fn -> Application.put_env(:converger, ConvergerWeb.Protocol, previous) end)

      other = conversation_fixture(ctx.tenant, ctx.widget)
      {_welcome, agent} = agent(ctx)

      agent =
        Client.push(agent, envelope(ctx.conversation, %{"type" => "typing", "isTyping" => true}))

      _agent = Client.push(agent, envelope(other, %{"type" => "typing", "isTyping" => true}))

      {id, %{"data" => %{"code" => "too_many_subscriptions"}}, _} = recv_enveloped(agent, "error")
      assert id == ctx.conversation.id
    end
  end

  describe "agent groups" do
    test "each conversation is served by one member of a group", ctx do
      {_welcome, a} = agent(ctx, %{"group" => "workers"}, user_id: "agent-a")
      {_welcome, b} = agent(ctx, %{"group" => "workers"}, user_id: "agent-b")
      {_welcome, user} = user(ctx)

      _user = Client.push(user, %{"type" => "text", "data" => %{"text" => "hi"}})

      received =
        for client <- [a, b] do
          case Client.recv(client, 1_000) do
            {%{"conversationId" => _, "frame" => %{"type" => "text"}}, _} -> 1
            _ -> 0
          end
        end

      assert Enum.sum(received) == 1
    end
  end
end
