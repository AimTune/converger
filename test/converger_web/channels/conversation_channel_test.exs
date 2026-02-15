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
    assert_broadcast "new_activity", %{text: "echo me", sender: "user"}
    # Assert broadcast of echo message from bot
    assert_broadcast "new_activity", %{text: "echo me", sender: "bot"}
  end
end
