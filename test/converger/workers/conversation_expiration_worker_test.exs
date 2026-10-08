defmodule Converger.Workers.ConversationExpirationWorkerTest do
  use Converger.DataCase, async: true
  use Oban.Testing, repo: Converger.Repo

  alias Converger.Workers.ConversationExpirationWorker
  alias Converger.Conversations
  alias Converger.Conversations.Conversation
  alias Converger.Activities
  alias Converger.Repo

  import Ecto.Query
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    %{tenant: tenant, channel: channel}
  end

  defp age(conversation, hours) do
    time = DateTime.utc_now() |> DateTime.add(-hours, :hour)

    from(c in Conversation, where: c.id == ^conversation.id)
    |> Repo.update_all(set: [inserted_at: time, updated_at: time])
  end

  test "closes conversations with no activity in the last 24h", %{
    tenant: tenant,
    channel: channel
  } do
    # 1. Fresh conversation (stays active)
    c1 = conversation_fixture(tenant, channel)

    # 2. Old conversation with recent activity (stays active): adding an
    #    activity bumps the conversation's updated_at.
    c2 = conversation_fixture(tenant, channel)
    age(c2, 48)
    activity_fixture(tenant, c2, %{text: "recent activity"})

    # 3. Old conversation with no activity (closed)
    c3 = conversation_fixture(tenant, channel)
    age(c3, 48)

    # 4. Old conversation whose last activity is old (closed)
    c4 = conversation_fixture(tenant, channel)
    activity_fixture(tenant, c4, %{text: "old activity"})
    age(c4, 48)

    # 5. Already closed (left alone, no new event)
    c5 = conversation_fixture(tenant, channel, %{status: "closed"})
    age(c5, 48)

    assert :ok = perform_job(ConversationExpirationWorker, %{})

    assert Repo.get(Conversation, c1.id).status == "active"
    assert Repo.get(Conversation, c2.id).status == "active"
    assert Repo.get(Conversation, c3.id).status == "closed"
    assert Repo.get(Conversation, c4.id).status == "closed"
    assert Repo.get(Conversation, c5.id).status == "closed"

    # Each expired conversation ends with a system conversationUpdate event.
    for c <- [c3, c4] do
      last = c.id |> Activities.list_activities_for_conversation() |> List.last()
      assert last.type == "conversationUpdate"
      assert last.sender == "system"

      assert last.metadata == %{
               "event" => "conversation_closed",
               "status" => "closed",
               "reason" => "expired"
             }
    end

    assert Activities.list_activities_for_conversation(c5.id) == []

    # Expired conversations reject new activities.
    assert {:error, :conversation_closed} =
             Activities.create_activity(%{
               tenant_id: tenant.id,
               conversation_id: c3.id,
               sender: "user",
               text: "too late"
             })
  end

  test "inactivity window is configurable via job args", %{tenant: tenant, channel: channel} do
    c = conversation_fixture(tenant, channel)
    age(c, 3)

    assert :ok = perform_job(ConversationExpirationWorker, %{})
    assert Repo.get(Conversation, c.id).status == "active"

    assert :ok = perform_job(ConversationExpirationWorker, %{"inactivity_hours" => 2})
    assert Repo.get(Conversation, c.id).status == "closed"
  end

  test "expiration query uses the (status, updated_at) index" do
    # The test table is tiny, so forbid sequential scans to see whether the
    # planner *can* serve the query from an index.
    Repo.query!("SET LOCAL enable_seqscan = off")

    plan =
      Repo.explain(:all, Conversations.inactive_conversations_query(DateTime.utc_now()))

    assert plan =~ "conversations_status_updated_at_index"
  end

  test "max_attempts is 3" do
    assert ConversationExpirationWorker.__opts__()[:max_attempts] == 3
  end
end
