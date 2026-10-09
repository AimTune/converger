defmodule ConvergerWeb.SocketsTest do
  use ConvergerWeb.ChannelCase, async: false

  # The legacy socket logs a deprecation warning per connection.
  @moduletag :capture_log

  alias Converger.Auth.{ConvergerToken, Token}
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket, ConversationChannel, Sockets, UserSocket}

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    %{tenant: tenant, channel: channel}
  end

  defp converger_socket(channel, conversation, user_id) do
    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(channel, conversation.id, user_id: user_id)

    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})
    socket
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  test "socket ids are per user, not per channel", %{tenant: tenant, channel: channel} do
    conversation = conversation_fixture(tenant, channel)
    alice = converger_socket(channel, conversation, "alice")
    bob = converger_socket(channel, conversation, "bob")

    assert alice.id == "converger_socket:#{tenant.id}:user:alice"
    assert bob.id == "converger_socket:#{tenant.id}:user:bob"

    # Without a user id the conversation is the subject.
    {:ok, token, _} = ConvergerToken.generate_conversation_token(channel, conversation.id)
    {:ok, anon} = connect(ConvergerSocket, %{"token" => token})
    assert anon.id == "converger_socket:#{tenant.id}:conversation:#{conversation.id}"
  end

  test "legacy socket ids are tenant scoped", %{tenant: tenant, channel: channel} do
    other_tenant = tenant_fixture()
    other_channel = channel_fixture(other_tenant)

    {:ok, t1, _} = Token.generate_token(conversation_fixture(tenant, channel), tenant, "user-1")

    {:ok, t2, _} =
      Token.generate_token(
        conversation_fixture(other_tenant, other_channel),
        other_tenant,
        "user-1"
      )

    {:ok, s1} = connect(UserSocket, %{"token" => t1})
    {:ok, s2} = connect(UserSocket, %{"token" => t2})
    assert s1.id != s2.id
  end

  test "disconnecting one user does not affect other users of the same channel", %{
    tenant: tenant,
    channel: channel
  } do
    conversation = conversation_fixture(tenant, channel)
    alice = converger_socket(channel, conversation, "alice")
    bob = converger_socket(channel, conversation, "bob")

    # The transport of each socket listens on its id; observe both.
    ConvergerWeb.Endpoint.subscribe(alice.id)
    ConvergerWeb.Endpoint.subscribe(bob.id)

    Sockets.disconnect_user(tenant.id, "alice")

    alice_id = alice.id
    bob_id = bob.id
    assert_receive %Phoenix.Socket.Broadcast{topic: ^alice_id, event: "disconnect"}
    refute_receive %Phoenix.Socket.Broadcast{topic: ^bob_id, event: "disconnect"}, 100
  end

  test "deactivating a channel disconnects its sockets and blocks reconnects", %{
    tenant: tenant,
    channel: channel
  } do
    conversation = conversation_fixture(tenant, channel)
    alice = converger_socket(channel, conversation, "alice")

    {:ok, _, _} =
      subscribe_and_join(alice, ConvergerChannel, "converger:conversation:#{conversation.id}")

    {:ok, legacy_token, _} = Token.generate_token(conversation, tenant, "legacy-user")
    {:ok, legacy} = connect(UserSocket, %{"token" => legacy_token})

    {:ok, _, _} =
      subscribe_and_join(legacy, ConversationChannel, "conversation:#{conversation.id}")

    wait_until(fn -> Sockets.count(channel.id) == 2 end)

    # A socket of another channel must stay connected.
    other_channel = channel_fixture(tenant)
    other_conversation = conversation_fixture(tenant, other_channel)
    carol = converger_socket(other_channel, other_conversation, "carol")

    {:ok, _, _} =
      subscribe_and_join(
        carol,
        ConvergerChannel,
        "converger:conversation:#{other_conversation.id}"
      )

    for id <- [alice.id, legacy.id, carol.id], do: ConvergerWeb.Endpoint.subscribe(id)

    {:ok, _} = Converger.Channels.update_channel(channel, %{status: "inactive"})

    alice_id = alice.id
    legacy_id = legacy.id
    carol_id = carol.id
    assert_receive %Phoenix.Socket.Broadcast{topic: ^alice_id, event: "disconnect"}, 2_000
    assert_receive %Phoenix.Socket.Broadcast{topic: ^legacy_id, event: "disconnect"}, 2_000
    refute_receive %Phoenix.Socket.Broadcast{topic: ^carol_id, event: "disconnect"}, 100

    # Reconnecting with the still-valid token is refused.
    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(channel, conversation.id, user_id: "alice")

    assert :error = connect(ConvergerSocket, %{"token" => token})

    assert {:error, %{reason: "channel_inactive"}} =
             legacy
             |> subscribe_and_join(ConversationChannel, "conversation:#{conversation.id}")
  end

  test "token endpoints carry the user id", %{channel: channel} do
    {:ok, token, _} = ConvergerToken.generate_token(channel, user_id: "dana")
    {:ok, claims} = ConvergerToken.verify_token(token)
    assert claims["user_id"] == "dana"
  end
end
