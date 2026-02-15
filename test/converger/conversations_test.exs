defmodule Converger.ConversationsTest do
  use Converger.DataCase

  alias Converger.Conversations

  describe "conversations" do
    alias Converger.Conversations.Conversation

    import Converger.TenantsFixtures
    import Converger.ChannelsFixtures
    import Converger.ConversationsFixtures

    setup do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      %{tenant: tenant, channel: channel}
    end

    test "list_conversations/0 returns all conversations", %{tenant: tenant, channel: channel} do
      conversation = conversation_fixture(tenant, channel)
      assert Conversations.list_conversations() == [conversation]
    end

    test "create_conversation/1 with metadata creates a conversation", %{
      tenant: tenant,
      channel: channel
    } do
      metadata = %{"user_id" => "123", "source" => "web"}

      valid_attrs = %{
        status: "active",
        tenant_id: tenant.id,
        channel_id: channel.id,
        metadata: metadata
      }

      assert {:ok, %Conversation{} = conversation} =
               Conversations.create_conversation(valid_attrs)

      assert conversation.metadata == metadata
    end

    test "conversations are scoped to tenant", %{tenant: tenant, channel: channel} do
      tenant2 = tenant_fixture()
      channel2 = channel_fixture(tenant2)
      conv1 = conversation_fixture(tenant, channel)
      _conv2 = conversation_fixture(tenant2, channel2)

      assert Conversations.list_conversations_for_tenant(tenant.id) == [conv1]
    end

    test "update_conversation/2 can close conversation", %{tenant: tenant, channel: channel} do
      conversation = conversation_fixture(tenant, channel)

      assert {:ok, %Conversation{} = updated} =
               Conversations.update_conversation(conversation, %{status: "closed"})

      assert updated.status == "closed"
    end
  end
end
