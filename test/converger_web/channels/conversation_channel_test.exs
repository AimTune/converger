defmodule ConvergerWeb.ConversationChannelTest do
  use ConvergerWeb.ChannelCase

  alias Converger.Auth.Token
  alias ConvergerWeb.UserSocket
  alias ConvergerWeb.ConversationChannel

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  # The pipeline (inline in tests) runs in the channel process before it
  # replies, so replies get more than the 100 ms default on a loaded machine.
  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    {:ok, token, _claims} = Token.generate_token(conversation, tenant, "user-1")

    {:ok, socket} = connect(UserSocket, %{"token" => token})

    %{socket: socket, conversation: conversation, tenant: tenant, token: token}
  end

  test "WS payload cannot set sender or inserted_at; idempotency_key is namespaced", %{
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

    assert_reply ref, :ok, %{id: id, seq: 1}, 1_000

    [activity] = Converger.Activities.list_activities_for_conversation(conversation.id)
    assert activity.id == id
    assert activity.sender == "user-1"
    assert activity.idempotency_key == "ws:user-1:from-client"
    assert activity.inserted_at.year >= 2026
  end

  describe "idempotent re-push" do
    setup %{socket: socket, conversation: conversation} do
      {:ok, _, socket} =
        subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}")

      %{socket: socket}
    end

    test "the same key returns the stored activity instead of a duplicate", %{
      socket: socket,
      conversation: conversation
    } do
      ref = push(socket, "new_activity", %{"text" => "once", "idempotency_key" => "k-1"})
      assert_reply ref, :ok, %{id: id, seq: 1}, 1_000

      # e.g. the client lost the connection before the reply and re-sends
      ref = push(socket, "new_activity", %{"text" => "once", "idempotency_key" => "k-1"})
      assert_reply ref, :ok, %{id: ^id, seq: 1}, 1_000

      assert [%{id: ^id}] = Converger.Activities.list_activities_for_conversation(conversation.id)
    end

    test "survives a reconnect (new socket, same user)", %{
      socket: socket,
      conversation: conversation,
      token: token
    } do
      ref = push(socket, "new_activity", %{"text" => "once", "idempotency_key" => "k-2"})
      assert_reply ref, :ok, %{id: id}, 1_000

      {:ok, socket2} = connect(UserSocket, %{"token" => token})

      {:ok, _, socket2} =
        subscribe_and_join(socket2, ConversationChannel, "conversation:#{conversation.id}")

      ref = push(socket2, "new_activity", %{"text" => "once", "idempotency_key" => "k-2"})
      assert_reply ref, :ok, %{id: ^id}, 1_000

      assert [_] = Converger.Activities.list_activities_for_conversation(conversation.id)
    end

    test "keys of different senders and of the REST API do not collide", %{
      socket: socket,
      conversation: conversation,
      tenant: tenant
    } do
      {:ok, rest} =
        Converger.Activities.create_client_activity(%{"text" => "rest"}, %{
          tenant_id: tenant.id,
          conversation_id: conversation.id,
          sender: "bot",
          idempotency_key: "shared"
        })

      ref = push(socket, "new_activity", %{"text" => "user-1", "idempotency_key" => "shared"})
      assert_reply ref, :ok, %{id: id1}, 1_000

      {:ok, token2, _} = Token.generate_token(conversation, tenant, "user-2")
      {:ok, socket2} = connect(UserSocket, %{"token" => token2})

      {:ok, _, socket2} =
        subscribe_and_join(socket2, ConversationChannel, "conversation:#{conversation.id}")

      ref = push(socket2, "new_activity", %{"text" => "user-2", "idempotency_key" => "shared"})
      assert_reply ref, :ok, %{id: id2}, 1_000

      assert Enum.uniq([rest.id, id1, id2]) |> length() == 3

      assert ~w(rest user-1 user-2) ==
               conversation.id
               |> Converger.Activities.list_activities_for_conversation()
               |> Enum.map(& &1.text)
    end

    test "rejects an invalid key", %{socket: socket, conversation: conversation} do
      for key <- ["", 42, String.duplicate("k", 256)] do
        ref = push(socket, "new_activity", %{"text" => "x", "idempotency_key" => key})

        assert_reply ref, :error, %{
          reason: "invalid_activity",
          errors: %{idempotency_key: [_]}
        }
      end

      ref = push(socket, "new_activity", %{"text" => "no key", "idempotency_key" => nil})
      assert_reply ref, :ok, %{}, 1_000

      assert [%{idempotency_key: nil}] =
               Converger.Activities.list_activities_for_conversation(conversation.id)
    end
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

  test "closing notifies subscribers and later pushes reply conversation_closed", %{
    socket: socket,
    conversation: conversation
  } do
    {:ok, _, socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}")

    {:ok, _} = Converger.Conversations.close_conversation(conversation)

    assert_broadcast "new_activity", %{
      type: "conversationUpdate",
      metadata: %{"event" => "conversation_closed"}
    }

    ref = push(socket, "new_activity", %{"text" => "too late"})
    assert_reply ref, :error, %{reason: "conversation_closed"}

    assert [%{type: "conversationUpdate"}] =
             Converger.Activities.list_activities_for_conversation(conversation.id)
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
      assert_reply ref, :ok, %{}, 1_000

      assert_receive {:webhook_request, %{"text" => "[WS] hi there", "id" => activity_id}}
      refute_receive {:webhook_request, _}, 200

      delivery =
        Converger.Deliveries.get_delivery_for_activity_and_channel(activity_id, channel.id)

      assert delivery.status == "sent"
      assert delivery.attempts == 1
    end
  end
end
