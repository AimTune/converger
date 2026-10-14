defmodule Converger.Channels.MekikIntegrationTest do
  @moduledoc """
  The `mekik` channel adapter (Mode A of #64) end to end: an end user on a
  `websocket` widget channel (a real native v1 socket, every server frame
  validated against the v1 schemas by `ConvergerWeb.ProtocolClient`), a
  routing rule from the widget to a `mekik` channel, and a fake mekik/1
  server (`Converger.FakeMekikServer`) the adapter dials per conversation.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Channels, RoutingRules}
  alias Converger.Auth.ConvergerToken
  alias Converger.Channels.Adapters.Mekik
  alias Converger.Channels.Mekik.{Connection, Connections, Relay, Sessions}
  alias Converger.FakeMekikServer
  alias ConvergerWeb.ProtocolClient, as: Client

  setup do
    webhook = Application.get_env(:converger, :webhook, [])

    Application.put_env(
      :converger,
      :webhook,
      Keyword.put(webhook, :allow_private_targets, true)
    )

    on_exit(fn -> Application.put_env(:converger, :webhook, webhook) end)
    :ok
  end

  defp start_mekik(opts \\ []) do
    {:ok, fake} = FakeMekikServer.start_link(self(), opts)
    on_exit(fn -> FakeMekikServer.stop(fake) end)
    fake
  end

  defp setup_channels(fake, config \\ %{}) do
    tenant = tenant_fixture()
    widget = channel_fixture(tenant)

    mekik =
      channel_fixture(tenant,
        type: "mekik",
        config: Map.merge(%{"url" => fake.url, "meta" => %{"brand" => "acme"}}, config)
      )

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "widget to mekik",
        tenant_id: tenant.id,
        source_channel_id: widget.id,
        target_channel_ids: [mekik.id]
      })

    conversation = conversation_fixture(tenant, widget)
    :ok = Relay.watch(mekik.id)
    on_exit(fn -> Connections.stop_channel(mekik.id) end)

    %{tenant: tenant, widget: widget, mekik: mekik, conversation: conversation}
  end

  defp user(ctx, port) do
    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(ctx.widget, ctx.conversation.id,
        user_id: "alice"
      )

    {:ok, client} = Client.connect(port, headers: [{"authorization", "Bearer #{token}"}])
    client = Client.push(client, %{"type" => "hello"})
    {%{"type" => "welcome"}, client} = Client.recv(client)
    client
  end

  # The next client frame the fake server received of `type`.
  defp upstream(type, timeout \\ 3_000) do
    receive do
      {:mekik_frame, socket, %{"type" => ^type} = frame} -> {socket, frame}
      {:mekik_frame, _socket, _other} -> upstream(type, timeout)
    after
      timeout -> flunk("mekik server received no #{type}")
    end
  end

  defp connected(timeout \\ 3_000) do
    assert_receive {:mekik_connected, socket, hello}, timeout
    {socket, hello}
  end

  defp stored(conversation), do: Activities.list_activities_since(conversation.id, nil)

  defp message_types(conversation) do
    conversation |> stored() |> Enum.map(&(&1.message_type || &1.text))
  end

  defp eventually(fun, attempts \\ 50) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("condition never held")
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  describe "a scripted refund turn (run, tool_call, interrupt, resume)" do
    setup do
      fake = start_mekik()
      Map.merge(setup_channels(fake), %{fake: fake, port: Client.start_server()})
    end

    test "user turns go upstream; the bot's frames are stored and reach the end user", ctx do
      user = user(ctx, ctx.port)

      user =
        Client.push(user, %{
          "type" => "text",
          "clientId" => "u-1",
          "data" => %{"text" => "ORD-42"},
          "meta" => %{"locale" => "tr-TR"}
        })

      assert {%{"type" => "ack"}, user} = Client.recv(user)

      {_socket, hello} = connected()
      assert hello["userId"] == "converger:" <> ctx.conversation.id
      assert hello["watermark"] == 0
      refute Map.has_key?(hello, "conversationId")
      assert hello["meta"] == %{"brand" => "acme"}

      {_socket, turn} = upstream("text")
      assert turn["data"] == %{"text" => "ORD-42"}
      assert turn["meta"]["locale"] == "tr-TR"
      assert turn["meta"]["brand"] == "acme"
      assert turn["meta"]["conversationId"] == ctx.conversation.id
      assert turn["meta"]["channel"] == %{"id" => ctx.widget.id, "type" => "websocket"}

      {run, user} = Client.recv_type(user, "run", 3_000)
      assert run["data"]["status"] == "started"
      {running, user} = Client.recv_type(user, "tool_call", 3_000)
      assert running["data"]["status"] == "running"
      {completed, user} = Client.recv_type(user, "tool_call", 3_000)
      assert completed["data"]["status"] == "completed"
      {interrupt, user} = Client.recv_type(user, "interrupt", 3_000)
      assert interrupt["id"] == "int-1"
      assert [%{"label" => "Approve"}, %{"label" => "Reject"}] = interrupt["data"]["actions"]
      {run, user} = Client.recv_type(user, "run", 3_000)
      assert run["data"]["status"] == "interrupted"

      assert message_types(ctx.conversation) == ["ORD-42", "tool_call", "tool_call", "interrupt"]

      [_turn, _running, _completed, stored_interrupt] = stored(ctx.conversation)
      assert stored_interrupt.sender == "mekik"
      assert stored_interrupt.source_channel_id == ctx.mekik.id
      assert stored_interrupt.payload["id"] == "int-1"

      # The end user taps "Approve": a reply to the interrupt with the action.
      user =
        Client.push(user, %{
          "type" => "text",
          "clientId" => "u-2",
          "data" => %{"text" => "Approve"},
          "replyTo" => %{"id" => stored_interrupt.id, "seq" => interrupt["seq"]},
          "metadata" => %{
            "action" => %{
              "label" => "Approve",
              "value" => %{"approved" => true},
              "source" => "web"
            }
          }
        })

      {_socket, resume} = upstream("resume")
      assert resume == %{"type" => "resume", "answers" => %{"int-1" => %{"approved" => true}}}

      {resolved, user} = Client.recv_type(user, "interrupt_resolved", 3_000)
      assert resolved["id"] == "int-1"
      {reply, user} = Client.recv_type(user, "text", 3_000)
      assert %{"from" => "bot", "data" => %{"text" => "Refund complete: ORD-42"}} = reply
      {run, _user} = Client.recv_type(user, "run", 3_000)
      assert run["data"]["status"] == "finished"

      eventually(fn -> length(stored(ctx.conversation)) == 7 end)

      assert message_types(ctx.conversation) ==
               [
                 "ORD-42",
                 "tool_call",
                 "tool_call",
                 "interrupt",
                 "Approve",
                 "interrupt_resolved",
                 "text"
               ]

      refute Activities.interrupt_open?(ctx.conversation.id, "int-1")

      # The mekik conversation is recorded for a later resume.
      [conversation_id] = FakeMekikServer.conversations(ctx.fake)
      session = Sessions.get(ctx.mekik.id, ctx.conversation.id)
      assert session.mekik_conversation_id == conversation_id
    end

    test "a native resume from the end user is forwarded upstream", ctx do
      user = user(ctx, ctx.port)
      user = Client.push(user, %{"type" => "text", "data" => %{"text" => "ORD-42"}})
      {_interrupt, user} = Client.recv_type(user, "interrupt", 3_000)

      user =
        Client.push(user, %{"type" => "resume", "answers" => %{"int-1" => %{"approved" => false}}})

      {_socket, resume} = upstream("resume")
      assert resume["answers"] == %{"int-1" => %{"approved" => false}}

      {reply, _user} = Client.recv_type(user, "text", 3_000)
      assert reply["data"]["text"] == "Refund declined."
    end

    test "a rich user message travels as a text turn carrying the typed message", ctx do
      user = user(ctx, ctx.port)

      _user =
        Client.push(user, %{
          "type" => "location",
          "data" => %{"latitude" => 41.0, "longitude" => 29.0, "name" => "Office"}
        })

      {_socket, turn} = upstream("text")
      assert turn["data"]["message"]["type"] == "location"
      assert turn["data"]["message"]["data"]["name"] == "Office"
      assert is_binary(turn["data"]["text"])
    end
  end

  describe "resume and de-duplication" do
    setup do
      fake = start_mekik(greeting: "Hi! Send an order number.")
      setup_channels(fake) |> Map.put(:fake, fake)
    end

    defp deliver_turn(ctx, text) do
      {:ok, activity} =
        Activities.create_activity(%{
          "type" => "message",
          "sender" => "alice",
          "text" => text,
          "tenant_id" => ctx.tenant.id,
          "conversation_id" => ctx.conversation.id,
          "source_channel_id" => ctx.widget.id
        })

      activity
    end

    test "missed frames are replayed after a reconnect and stored once", ctx do
      deliver_turn(ctx, "hello")
      {socket, _hello} = connected()
      {_socket, %{"data" => %{"text" => "hello"}}} = upstream("text")

      # greeting, echo of "hello" (skipped), "echo: hello"
      eventually(fn -> length(stored(ctx.conversation)) == 3 end)

      assert Enum.map(stored(ctx.conversation), & &1.text) ==
               ["hello", "Hi! Send an order number.", "echo: hello"]

      [mekik_conversation] = FakeMekikServer.conversations(ctx.fake)

      # A frame the connection never saw, then the connection drops.
      FakeMekikServer.emit(
        ctx.fake,
        mekik_conversation,
        %{
          "type" => "text",
          "id" => "msg-missed",
          "from" => "bot",
          "data" => %{"text" => "missed"}
        },
        push: false
      )

      FakeMekikServer.close(socket, 1001, "going away")

      {socket, hello} = connected()
      assert hello["conversationId"] == mekik_conversation
      assert hello["watermark"] == 3

      eventually(fn -> length(stored(ctx.conversation)) == 4 end)
      assert List.last(stored(ctx.conversation)).text == "missed"

      # Another drop: nothing new to replay, nothing stored twice.
      FakeMekikServer.close(socket, 1001, "going away")
      {_socket, hello} = connected()
      assert hello["watermark"] == 4
      Process.sleep(200)
      assert length(stored(ctx.conversation)) == 4
    end

    test "a restarted connection resumes the recorded mekik conversation", ctx do
      deliver_turn(ctx, "one")
      {_socket, _hello} = connected()
      eventually(fn -> length(stored(ctx.conversation)) == 3 end)
      [mekik_conversation] = FakeMekikServer.conversations(ctx.fake)

      pid = Connections.whereis(ctx.mekik.id, ctx.conversation.id)
      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(Connections, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert Sessions.get(ctx.mekik.id, ctx.conversation.id).watermark == 3

      deliver_turn(ctx, "two")
      {_socket, hello} = connected()
      assert hello["conversationId"] == mekik_conversation
      assert hello["watermark"] == 3

      eventually(fn -> length(stored(ctx.conversation)) == 5 end)
      assert List.last(stored(ctx.conversation)).text == "echo: two"
      # No second greeting, no new mekik conversation.
      assert FakeMekikServer.conversations(ctx.fake) == [mekik_conversation]
    end

    test "a mekik conversation that is gone starts over at watermark 0", ctx do
      deliver_turn(ctx, "one")
      {socket, _hello} = connected()
      eventually(fn -> length(stored(ctx.conversation)) == 3 end)

      FakeMekikServer.reset(ctx.fake)
      FakeMekikServer.close(socket, 1001, "restart")

      {_socket, hello} = connected()
      assert hello["conversationId"] == "conv-1"

      # The server minted a new conversation (and greeted again).
      eventually(fn -> length(stored(ctx.conversation)) == 4 end)
      session = Sessions.get(ctx.mekik.id, ctx.conversation.id)
      assert session.mekik_conversation_id == "conv-2"
    end
  end

  describe "connection lifecycle" do
    test "a wrong token fails the delivery permanently (close 4401)" do
      fake = start_mekik(token: "secret")
      ctx = setup_channels(fake, %{"token" => "wrong"})

      {:ok, activity} =
        Activities.create_activity(%{
          "type" => "message",
          "sender" => "alice",
          "text" => "hi",
          "tenant_id" => ctx.tenant.id,
          "conversation_id" => ctx.conversation.id,
          "source_channel_id" => ctx.widget.id
        })

      {_socket, hello} = connected()
      assert hello["token"] == "wrong"

      delivery = Converger.Deliveries.get_or_create_delivery(activity, ctx.mekik.id)
      eventually(fn -> Converger.Repo.reload(delivery).status == "failed" end)
      assert stored(ctx.conversation) |> length() == 1

      # With the right token the next attempt goes through.
      {:ok, channel} =
        Channels.update_channel(ctx.mekik, %{config: %{"url" => fake.url, "token" => "secret"}})

      assert {:ok, _info} = Mekik.deliver_activity(channel, activity)
      {_socket, hello} = connected()
      assert hello["token"] == "secret"
    end

    test "an idle connection stops; the next delivery opens a new one" do
      fake = start_mekik()
      ctx = setup_channels(fake)

      {:ok, pid} = Connections.ensure(ctx.mekik, ctx.conversation.id, idle_timeout_ms: 200)
      ref = Process.monitor(pid)
      {_socket, _hello} = connected()
      eventually(fn -> Connection.info(pid).phase == :ready end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert_receive {:mekik_closed, _socket}, 1_000
      assert Connections.whereis(ctx.mekik.id, ctx.conversation.id) == nil
    end

    test "the connection reconnects with backoff while the server is unreachable" do
      fake = start_mekik()
      ctx = setup_channels(fake)

      {:ok, pid} = Connections.ensure(ctx.mekik, ctx.conversation.id)
      {socket, _hello} = connected()

      # Refuse the next connects: the listener is gone.
      FakeMekikServer.stop_listener(fake)
      FakeMekikServer.close(socket, 1001)
      eventually(fn -> Connection.info(pid).phase in [:backoff, :connecting] end)

      assert {:error, _reason} = Connection.send_frame(pid, ctx.mekik, %{"type" => "abort"})
      assert Process.alive?(pid)
    end
  end
end
