defmodule Converger.Workers.ConversationExpirationWorkerTest do
  use Converger.DataCase, async: true
  use Oban.Testing, repo: Converger.Repo

  alias Converger.Workers.ConversationExpirationWorker
  alias Converger.Conversations.Conversation
  alias Converger.Activities.Activity
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

  test "closes conversations with no activity older than 24h", %{tenant: tenant, channel: channel} do
    # 1. Fresh conversation (should stay active)
    c1 = conversation_fixture(tenant, channel)

    # 2. Old conversation with recent activity (should stay active)
    c2 = conversation_fixture(tenant, channel)
    old_time = DateTime.utc_now() |> DateTime.add(-48, :hour) |> DateTime.truncate(:microsecond)

    from(c in Conversation, where: c.id == ^c2.id)
    |> Repo.update_all(set: [inserted_at: old_time])

    # Default insertion time is now
    activity_fixture(tenant, c2, %{text: "recent activity"})

    # 3. Old conversation with no activity (should be closed)
    c3 = conversation_fixture(tenant, channel)

    from(c in Conversation, where: c.id == ^c3.id)
    |> Repo.update_all(set: [inserted_at: old_time])

    # 4. Old conversation with old activity (should be closed)
    c4 = conversation_fixture(tenant, channel)

    from(c in Conversation, where: c.id == ^c4.id)
    |> Repo.update_all(set: [inserted_at: old_time])

    a4 = activity_fixture(tenant, c4, %{text: "old activity"})
    from(a in Activity, where: a.id == ^a4.id) |> Repo.update_all(set: [inserted_at: old_time])

    assert :ok = perform_job(ConversationExpirationWorker, %{})

    assert Repo.get(Conversation, c1.id).status == "active"
    assert Repo.get(Conversation, c2.id).status == "active"
    assert Repo.get(Conversation, c3.id).status == "closed"
    assert Repo.get(Conversation, c4.id).status == "closed"
  end

  test "max_attempts is 3" do
    assert ConversationExpirationWorker.__opts__()[:max_attempts] == 3
  end
end
