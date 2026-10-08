defmodule Converger.ActivitiesTest do
  use Converger.DataCase

  alias Converger.Activities

  describe "activities" do
    alias Converger.Activities.Activity

    import Converger.TenantsFixtures
    import Converger.ChannelsFixtures
    import Converger.ConversationsFixtures
    import Converger.ActivitiesFixtures

    setup do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel)
      %{tenant: tenant, conversation: conversation}
    end

    test "list_activities_for_conversation/1 orders by seq, not by clock", %{
      tenant: tenant,
      conversation: conversation
    } do
      # Clocks disagree with insertion order (e.g. skew between nodes):
      # the per-conversation sequence still decides.
      a1 =
        activity_fixture(tenant, conversation, %{
          inserted_at: ~U[2024-01-01 10:02:00Z],
          text: "first"
        })

      a2 =
        activity_fixture(tenant, conversation, %{
          inserted_at: ~U[2024-01-01 10:00:00Z],
          text: "second"
        })

      a3 =
        activity_fixture(tenant, conversation, %{
          inserted_at: ~U[2024-01-01 10:01:00Z],
          text: "third"
        })

      assert {a1.seq, a2.seq, a3.seq} == {1, 2, 3}

      activities = Activities.list_activities_for_conversation(conversation.id)
      assert Enum.map(activities, & &1.text) == ["first", "second", "third"]
    end

    test "activities are scoped to tenant", %{tenant: tenant, conversation: conversation} do
      tenant2 = tenant_fixture()
      channel2 = channel_fixture(tenant2)
      conv2 = conversation_fixture(tenant2, channel2)

      _a1 = activity_fixture(tenant, conversation, %{text: "tenant1"})
      _a2 = activity_fixture(tenant2, conv2, %{text: "tenant2"})

      # Verify context functions correctly scope by conversation (which is scoped to tenant)
      activities1 = Activities.list_activities_for_conversation(conversation.id)
      assert length(activities1) == 1
      assert hd(activities1).text == "tenant1"
    end

    test "create_activity/1 with valid data creates an activity", %{
      tenant: tenant,
      conversation: conversation
    } do
      valid_attrs = %{
        type: "message",
        sender: "user1",
        text: "hello",
        tenant_id: tenant.id,
        conversation_id: conversation.id
      }

      assert {:ok, %Activity{} = activity} = Activities.create_activity(valid_attrs)
      assert activity.sender == "user1"
      assert activity.text == "hello"
    end
  end
end
