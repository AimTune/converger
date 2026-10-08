defmodule ConvergerWeb.ConversationChannelTest do
  use ConvergerWeb.ChannelCase

  alias Converger.Auth.Token
  alias ConvergerWeb.UserSocket
  alias ConvergerWeb.ConversationChannel

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    {:ok, token, _claims} = Token.generate_token(conversation, tenant, "user-1")

    {:ok, socket} = connect(UserSocket, %{"token" => token})

    %{socket: socket, conversation: conversation, tenant: tenant, token: token}
  end

  test "WS payload cannot set sender, inserted_at or idempotency_key", %{
    socket: socket,
    conversation: conversation
  } do
    {:ok, _, socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}")

    ref =
      push(socket, "new_activity", %{
        "text" => "spoof",
        "sender" => "bot",
        "inserted_at" => "2001-01-01T00:00:00Z",
        "idempotency_key" => "from-client"
      })

    assert_reply ref, :ok

    [activity] = Converger.Activities.list_activities_for_conversation(conversation.id)
    assert activity.sender == "user-1"
    assert activity.idempotency_key == nil
    assert activity.inserted_at.year >= 2026
  end

  test "invalid WS payload replies with field-level errors", %{
    socket: socket,
    conversation: conversation
  } do
    {:ok, _, socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}")

    ref = push(socket, "new_activity", %{"text" => "x", "type" => "bogus"})
    assert_reply ref, :error, %{reason: "invalid_activity", errors: %{type: [_]}}
  end

  test "joins successfully with valid token", %{socket: socket, conversation: conversation} do
    {:ok, _, socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}")

    assert socket.topic == "conversation:#{conversation.id}"
  end

  test "broadcasts activity to subscribers", %{
    socket: socket,
    conversation: conversation,
    tenant: tenant
  } do
    {:ok, _, _socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}")

    Converger.Activities.create_activity(%{
      type: "message",
      sender: "user-2",
      text: "hello folks",
      tenant_id: tenant.id,
      conversation_id: conversation.id
    })

    assert_broadcast "new_activity", %{text: "hello folks"}
  end

  test "broadcast carries the full canonical activity", %{
    socket: socket,
    conversation: conversation,
    tenant: tenant
  } do
    {:ok, _, _socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}")

    {:ok, activity} =
      Converger.Activities.create_activity(%{
        type: "event",
        sender: "user-2",
        text: "with file",
        attachments: [%{"contentType" => "image/png", "contentUrl" => "https://x/a.png"}],
        metadata: %{"k" => "v"},
        tenant_id: tenant.id,
        conversation_id: conversation.id
      })

    assert_broadcast "new_activity", payload
    assert payload == Converger.Activities.Serializer.canonical(activity)
    assert payload.type == "event"
    assert [%{"contentUrl" => "https://x/a.png"}] = payload.attachments
    assert payload.metadata == %{"k" => "v"}
  end

  test "replays missed activities on reconnection", %{conversation: conversation, tenant: tenant} do
    # Create an old activity
    old_activity =
      activity_fixture(tenant, conversation, %{inserted_at: ~U[2024-01-01 10:00:00Z], text: "old"})

    # Create a new activity "while disconnected"
    activity_fixture(tenant, conversation, %{
      inserted_at: ~U[2024-01-01 10:05:00Z],
      text: "missed"
    })

    # Connect with last_activity_id = old_activity.id
    {:ok, token, _claims} = Token.generate_token(conversation, tenant, "user-1")
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    {:ok, _, _socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}", %{
        "last_activity_id" => old_activity.id
      })

    assert_push "new_activity", %{text: "missed"}
    refute_push "new_activity", %{text: "old"}
  end

  test "echoes messages if channel type is echo", %{tenant: tenant} do
    # Create echo channel
    echo_channel = channel_fixture(tenant, %{type: "echo"})
    conversation = conversation_fixture(tenant, echo_channel)

    {:ok, token, _} = Token.generate_token(conversation, tenant, "user-echo")
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}")

    # Send message
    push(socket, "new_activity", %{"text" => "echo me"})

    # Assert broadcast of user message
    assert_broadcast "new_activity", %{text: "echo me", sender: "user-echo"}
    # Assert broadcast of echo message from bot
    assert_broadcast "new_activity", %{text: "echo me", sender: "bot"}
    # Exactly one echo, and the echo itself is not echoed again
    refute_broadcast "new_activity", %{sender: "bot"}
    assert length(Converger.Activities.list_activities_for_conversation(conversation.id)) == 2
  end

  describe "delivery through the pipeline" do
    setup %{tenant: tenant} do
      previous = Application.get_env(:converger, :webhook_req_options)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:converger, :webhook_req_options, previous),
          else: Application.delete_env(:converger, :webhook_req_options)
      end)

      Application.put_env(:converger, :webhook_req_options,
        plug: {Req.Test, __MODULE__},
        retry: false
      )

      # Deliveries run in the channel process, not the test process.
      Req.Test.set_req_test_to_shared()
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:webhook_request, Jason.decode!(body)})
        Req.Test.json(conn, %{ok: true})
      end)

      channel =
        webhook_channel_fixture(tenant, %{
          transformations: [%{"type" => "add_prefix", "prefix" => "[WS] "}]
        })

      conversation = conversation_fixture(tenant, channel)
      {:ok, token, _} = Token.generate_token(conversation, tenant, "user-ws")
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _, socket} =
        subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}")

      %{socket: socket, channel: channel}
    end

    test "one WS message results in exactly one tracked, transformed delivery", %{
      socket: socket,
      channel: channel
    } do
      ref = push(socket, "new_activity", %{"text" => "hi there"})
      assert_reply ref, :ok

      assert_receive {:webhook_request, %{"text" => "[WS] hi there", "id" => activity_id}}
      refute_receive {:webhook_request, _}, 200

      delivery =
        Converger.Deliveries.get_delivery_for_activity_and_channel(activity_id, channel.id)

      assert delivery.status == "sent"
      assert delivery.attempts == 1
    end
  end
end
