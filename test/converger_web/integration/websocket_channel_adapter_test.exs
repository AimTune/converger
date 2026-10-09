defmodule ConvergerWeb.Integration.WebSocketChannelAdapterTest do
  # WhatsApp <-> agent console bridging through a `websocket` channel (#22).
  use ConvergerWeb.ChannelCase
  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.{Activities, Channels, Deliveries, Repo, RoutingRules}
  alias Converger.Activities.{Activity, Serializer}
  alias Converger.Auth.ConvergerToken
  alias Converger.Channels.InboundSignature
  alias Converger.ConvergerAPI.Watermark
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket, Sockets}

  @app_secret "meta-app-secret-ws-bridge"
  @phone "16505550022"

  setup do
    previous = Application.get_env(:converger, :whatsapp_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :whatsapp_req_options, previous),
        else: Application.delete_env(:converger, :whatsapp_req_options)
    end)

    Application.put_env(:converger, :whatsapp_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:whatsapp_request, Jason.decode!(body)})
      Req.Test.json(conn, %{"messages" => [%{"id" => "wamid.out-#{System.unique_integer()}"}]})
    end)

    tenant = tenant_fixture()

    {:ok, whatsapp} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "whatsapp_meta",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        transformations: [%{"type" => "add_prefix", "prefix" => "[Support] "}],
        config: %{
          "phone_number_id" => "106540352242922",
          "access_token" => "token",
          "verify_token" => "verify",
          "app_secret" => @app_secret
        }
      })

    console = channel_fixture(tenant, %{mode: "duplex"})

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "whatsapp to console",
        tenant_id: tenant.id,
        source_channel_id: whatsapp.id,
        target_channel_ids: [console.id]
      })

    %{tenant: tenant, whatsapp: whatsapp, console: console}
  end

  defp whatsapp_message(channel, id, text) do
    params = %{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "id" => "1",
          "changes" => [
            %{
              "field" => "messages",
              "value" => %{
                "messaging_product" => "whatsapp",
                "metadata" => %{"phone_number_id" => "106540352242922"},
                "contacts" => [%{"profile" => %{"name" => "Sheena"}, "wa_id" => @phone}],
                "messages" => [
                  %{
                    "from" => @phone,
                    "id" => id,
                    "timestamp" => "1749416383",
                    "type" => "text",
                    "text" => %{"body" => text}
                  }
                ]
              }
            }
          ]
        }
      ]
    }

    body = Jason.encode!(params)
    signature = "sha256=" <> InboundSignature.hmac_hex(@app_secret, body)

    [activity_id] =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(~p"/api/v1/channels/#{channel.id}/inbound", body)
      |> json_response(200)
      |> Map.fetch!("activity_ids")

    Repo.get!(Activity, activity_id)
  end

  defp connect_socket(channel, opts) do
    {:ok, token, _} = ConvergerToken.generate_token(channel, opts)
    {:ok, socket} = Phoenix.ChannelTest.connect(ConvergerSocket, %{"token" => token})
    socket
  end

  defp join_console(console) do
    socket = connect_socket(console, scope: "channel", user_id: "agent-7")

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:channel:#{console.id}")

    socket
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  defp delivery(activity, channel),
    do: Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)

  describe "WhatsApp -> websocket channel" do
    test "an inbound WhatsApp message reaches the connected agent console in real time", %{
      whatsapp: whatsapp,
      console: console
    } do
      join_console(console)
      wait_until(fn -> Sockets.count(console.id) == 1 end)

      activity = whatsapp_message(whatsapp, "wamid.in-1", "Where is my order?")
      conversation_id = activity.conversation_id

      assert_push "activitySet", %{conversation_id: ^conversation_id, activities: [frame]}
      assert frame.text == "Where is my order?"
      assert frame.from == %{id: @phone}

      # Tracked: delivered to one connected client.
      assert %{status: "sent", metadata: %{"connected_clients" => 1}} =
               delivery(activity, console)

      # Not echoed back to the WhatsApp user.
      refute_received {:whatsapp_request, _}
    end

    test "the agent's reply goes back to WhatsApp through the pipeline with middleware", %{
      whatsapp: whatsapp,
      console: console
    } do
      socket = join_console(console)
      inbound = whatsapp_message(whatsapp, "wamid.in-2", "hello")
      assert_push "activitySet", %{activities: [_]}

      ref =
        Phoenix.ChannelTest.push(socket, "postActivity", %{
          "conversation_id" => inbound.conversation_id,
          "text" => "On it",
          "clientId" => "reply-1"
        })

      assert_reply ref, :ok, %{id: id, seq: 2}, 2_000

      reply = Repo.get!(Activity, id)
      assert reply.conversation_id == inbound.conversation_id
      assert reply.sender == "agent-7"

      # The WhatsApp channel's middleware ran before the adapter.
      assert_received {:whatsapp_request, %{"to" => @phone, "text" => %{"body" => body}}}
      assert body == "[Support] On it"
      assert %{status: "sent"} = delivery(reply, whatsapp)

      # A re-send with the same key does not create a second activity.
      ref =
        Phoenix.ChannelTest.push(socket, "postActivity", %{
          "conversation_id" => inbound.conversation_id,
          "text" => "On it",
          "clientId" => "reply-1"
        })

      assert_reply ref, :ok, %{id: ^id, seq: 2}
    end

    test "a conversation the channel is not routed to cannot be written or joined", %{
      tenant: tenant,
      console: console
    } do
      socket = join_console(console)
      other = channel_fixture(tenant)
      {:ok, conversation} = create_conversation(tenant, other)

      ref =
        Phoenix.ChannelTest.push(socket, "postActivity", %{
          "conversation_id" => conversation.id,
          "text" => "x"
        })

      assert_reply ref, :error, %{reason: "unauthorized"}

      assert {:error, %{reason: "unauthorized"}} =
               console
               |> connect_socket(scope: "channel")
               |> subscribe_and_join(
                 ConvergerChannel,
                 "converger:conversation:#{conversation.id}"
               )
    end

    test "an unscoped channel token cannot join a routed conversation", %{
      whatsapp: whatsapp,
      console: console
    } do
      activity = whatsapp_message(whatsapp, "wamid.u-1", "hi")

      assert {:error, %{reason: "unauthorized"}} =
               console
               |> connect_socket(user_id: "end-user")
               |> subscribe_and_join(
                 ConvergerChannel,
                 "converger:conversation:#{activity.conversation_id}"
               )
    end

    test "the channel topic requires a channel-scoped token", %{console: console} do
      assert {:error, %{reason: "unauthorized"}} =
               console
               |> connect_socket(user_id: "end-user")
               |> subscribe_and_join(ConvergerChannel, "converger:channel:#{console.id}")
    end
  end

  describe "routed conversation topic" do
    test "a socket of the routed channel follows one conversation, after its middleware", %{
      whatsapp: whatsapp,
      console: console
    } do
      {:ok, console} =
        Channels.update_channel(console, %{
          transformations: [%{"type" => "add_prefix", "prefix" => "[WA] "}]
        })

      first = whatsapp_message(whatsapp, "wamid.r-1", "first")

      {:ok, _, _socket} =
        console
        |> connect_socket(scope: "channel", user_id: "agent-8")
        |> subscribe_and_join(
          ConvergerChannel,
          "converger:conversation:#{first.conversation_id}",
          %{"watermark" => Watermark.encode(0)}
        )

      # Replay and live frames both carry the channel's middleware.
      assert_push "activitySet", %{activities: [%{text: "[WA] first"}]}

      wait_until(fn -> Sockets.count_connections(console.id, first.conversation_id) == 1 end)
      whatsapp_message(whatsapp, "wamid.r-2", "second")
      assert_push "activitySet", %{activities: [%{text: "[WA] second"}], has_more: false}
    end

    test "a missing seq is filled from the database, duplicates are dropped", %{
      whatsapp: whatsapp,
      console: console
    } do
      {:ok, console} =
        Channels.update_channel(console, %{
          transformations: [%{"type" => "content_filter", "block_patterns" => ["secret"]}]
        })

      first = whatsapp_message(whatsapp, "wamid.g-1", "one")

      {:ok, _, socket} =
        console
        |> connect_socket(scope: "channel", user_id: "agent-9")
        |> subscribe_and_join(ConvergerChannel, "converger:conversation:#{first.conversation_id}")

      wait_until(fn -> Sockets.count_connections(console.id, first.conversation_id) == 1 end)

      # Halted by the console's middleware: never broadcast to the channel.
      whatsapp_message(whatsapp, "wamid.g-2", "a secret")
      third = whatsapp_message(whatsapp, "wamid.g-3", "three")

      # seq 3 arrives after 1: the gap (2) is read, filtered, and only 3 pushed.
      assert_push "activitySet", %{activities: [%{text: "three"}]}

      send(socket.channel_pid, %Phoenix.Socket.Broadcast{
        event: "new_activity",
        payload: Serializer.canonical(third)
      })

      refute_push "activitySet", _, 100
    end
  end

  describe "delivery tracking" do
    test "with no connected client the delivery stays pending until a replay", %{
      whatsapp: whatsapp,
      console: console
    } do
      activity = whatsapp_message(whatsapp, "wamid.off-1", "anyone there?")

      assert %{status: "pending", attempts: 1, metadata: %{"connected_clients" => 0}} =
               delivery(activity, console)

      {:ok, _, _} =
        console
        |> connect_socket(scope: "channel", user_id: "agent-1")
        |> subscribe_and_join(
          ConvergerChannel,
          "converger:conversation:#{activity.conversation_id}",
          %{"watermark" => Watermark.encode(0)}
        )

      assert_push "activitySet", %{activities: [%{text: "anyone there?"}]}
      wait_until(fn -> delivery(activity, console).status == "sent" end)
    end

    test "with require_ack the delivery is sent only after the client acks", %{
      whatsapp: whatsapp,
      console: console
    } do
      {:ok, console} = Channels.update_channel(console, %{config: %{"require_ack" => true}})
      socket = join_console(console)
      wait_until(fn -> Sockets.count(console.id) == 1 end)

      activity = whatsapp_message(whatsapp, "wamid.ack-1", "please ack")
      assert_push "activitySet", %{watermark: watermark}

      assert %{status: "pending", metadata: %{"connected_clients" => 1}} =
               delivery(activity, console)

      ref =
        Phoenix.ChannelTest.push(socket, "ack", %{
          "conversation_id" => activity.conversation_id,
          "watermark" => watermark
        })

      assert_reply ref, :ok, %{acknowledged: 1}
      assert %{status: "sent", sent_at: %DateTime{}} = delivery(activity, console)

      ref =
        Phoenix.ChannelTest.push(socket, "ack", %{"conversation_id" => "nope", "watermark" => 1})

      assert_reply ref, :error, %{reason: "invalid_ack"}
    end
  end

  test "an outbound-only websocket channel does not accept sends", %{tenant: tenant} do
    channel = channel_fixture(tenant, %{mode: "outbound"})
    {:ok, conversation} = create_conversation(tenant, channel)

    {:ok, _, socket} =
      channel
      |> connect_socket(conversation_id: conversation.id, user_id: "u-1")
      |> subscribe_and_join(ConvergerChannel, "converger:conversation:#{conversation.id}")

    ref = Phoenix.ChannelTest.push(socket, "postActivity", %{"text" => "hi"})
    assert_reply ref, :error, %{reason: "inbound_not_supported"}
    assert {[], false} = Activities.page_activities_since(conversation.id, nil)
  end

  test "an unknown event is answered and the channel stays joined", %{console: console} do
    socket = join_console(console)

    ref = Phoenix.ChannelTest.push(socket, "nonsense", %{})
    assert_reply ref, :error, %{reason: "bad_request"}

    ref = Phoenix.ChannelTest.push(socket, "ack", %{})
    assert_reply ref, :error, %{reason: "bad_request"}
  end

  test "tokens/generate issues channel-scoped tokens and rejects unknown scopes", %{
    tenant: tenant,
    console: console
  } do
    generate = fn body ->
      build_conn()
      |> put_req_header("authorization", "Bearer #{console.secret}")
      |> post(~p"/api/v1/converger/tokens/generate", body)
    end

    token = generate.(%{"scope" => "channel"}) |> json_response(200) |> Map.fetch!("token")
    {:ok, claims} = ConvergerToken.verify_token(token)
    assert claims["scope"] == "channel"

    {:ok, socket} = Phoenix.ChannelTest.connect(ConvergerSocket, %{"token" => token})
    assert socket.id == "converger_socket:#{tenant.id}:channel:#{console.id}"

    assert generate.(%{"scope" => "tenant"}) |> json_response(400)
  end

  defp create_conversation(tenant, channel) do
    Converger.Conversations.create_conversation(%{
      "tenant_id" => tenant.id,
      "channel_id" => channel.id
    })
  end
end
