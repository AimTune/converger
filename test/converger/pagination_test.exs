defmodule Converger.PaginationTest do
  use Converger.DataCase, async: false

  import Ecto.Query
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures
  import Converger.AuditLogsFixtures

  alias Converger.{Activities, Accounts, AuditLogs, Conversations, Pagination, Repo}
  alias Converger.Conversations.Conversation
  alias Converger.Pagination.Page

  setup do
    previous = Application.get_env(:converger, :pagination)
    on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)

    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    %{tenant: tenant, channel: channel}
  end

  defp put_limits(overrides) do
    Application.put_env(
      :converger,
      :pagination,
      Keyword.merge(Application.get_env(:converger, :pagination, []), overrides)
    )
  end

  describe "clamp_limit/2" do
    test "defaults, caps and parses" do
      put_limits(default_limit: 10, max_limit: 20, activity_default_limit: 5, activity_max_limit: 7)

      assert Pagination.clamp_limit(nil) == 10
      assert Pagination.clamp_limit(15) == 15
      assert Pagination.clamp_limit(1000) == 20
      assert Pagination.clamp_limit("12") == 12
      assert Pagination.clamp_limit("abc") == 10
      assert Pagination.clamp_limit(0) == 10
      assert Pagination.clamp_limit(-3) == 10
      assert Pagination.clamp_limit(nil, :activity) == 5
      assert Pagination.clamp_limit("999", :activity) == 7
    end
  end

  describe "cursors" do
    test "round-trip and reject garbage" do
      ts = DateTime.utc_now()
      id = Ecto.UUID.generate()

      assert {:ok, {^ts, ^id}} = ts |> Pagination.encode_cursor(id) |> Pagination.decode_cursor()
      assert {:ok, nil} = Pagination.decode_cursor(nil)
      assert {:ok, nil} = Pagination.decode_cursor("")
      assert {:error, :invalid_cursor} = Pagination.decode_cursor("not-a-cursor")
      assert {:error, :invalid_cursor} = Pagination.decode_cursor(Base.url_encode64("ts:x|y"))
      assert {:error, :invalid_cursor} = Pagination.decode_cursor(123)
    end
  end

  describe "conversations keyset" do
    setup %{tenant: tenant, channel: channel} do
      # Five conversations, two of them sharing a timestamp to exercise the id tiebreak.
      base = ~U[2026-01-01 00:00:00.000000Z]

      conversations =
        for i <- 0..4 do
          conversation = conversation_fixture(tenant, channel)
          ts = DateTime.add(base, min(i, 3), :second)

          from(c in Conversation, where: c.id == ^conversation.id)
          |> Repo.update_all(set: [inserted_at: ts])

          Repo.reload!(conversation)
        end

      %{conversations: conversations}
    end

    test "walks every row exactly once, newest first", %{tenant: tenant, conversations: all} do
      expected =
        all
        |> Enum.sort_by(&{&1.inserted_at, &1.id}, fn {t1, i1}, {t2, i2} ->
          case DateTime.compare(t1, t2) do
            :gt -> true
            :lt -> false
            :eq -> i1 >= i2
          end
        end)
        |> Enum.map(& &1.id)

      ids = walk(%{"tenant_id" => tenant.id}, limit: 2)
      assert ids == expected
    end

    test "ascending order", %{tenant: tenant, conversations: all} do
      ids = walk(%{"tenant_id" => tenant.id}, limit: 2, direction: :asc)
      assert Enum.sort(ids) == Enum.sort(Enum.map(all, & &1.id))
      assert ids == walk(%{"tenant_id" => tenant.id}, limit: 2) |> Enum.reverse()
    end

    test "has_more and next_cursor", %{tenant: tenant} do
      {:ok, %Page{entries: entries, has_more: true, next_cursor: cursor}} =
        Conversations.paginate_conversations(%{"tenant_id" => tenant.id}, limit: 3)

      assert length(entries) == 3
      assert is_binary(cursor)

      {:ok, %Page{entries: rest, has_more: false, next_cursor: nil}} =
        Conversations.paginate_conversations(%{"tenant_id" => tenant.id}, limit: 3, cursor: cursor)

      assert length(rest) == 2
    end

    test "invalid cursor", %{tenant: tenant} do
      assert {:error, :invalid_cursor} =
               Conversations.paginate_conversations(%{"tenant_id" => tenant.id}, cursor: "zzz")
    end

    test "search by id", %{tenant: tenant, conversations: [first | _]} do
      assert {:ok, %Page{entries: [%{id: id}]}} =
               Conversations.paginate_conversations(%{"tenant_id" => tenant.id, "q" => first.id})

      assert id == first.id

      assert {:ok, %Page{entries: []}} =
               Conversations.paginate_conversations(%{"q" => "not-a-uuid"})
    end

    test "list_conversations is bounded by the configured default", %{tenant: tenant} do
      put_limits(default_limit: 2)
      assert length(Conversations.list_conversations_for_tenant(tenant.id)) == 2
    end

    defp walk(filters, opts, cursor \\ nil, acc \\ []) do
      {:ok, page} = Conversations.paginate_conversations(filters, [cursor: cursor] ++ opts)
      acc = acc ++ Enum.map(page.entries, & &1.id)
      if page.has_more, do: walk(filters, opts, page.next_cursor, acc), else: acc
    end
  end

  describe "activities by seq" do
    setup %{tenant: tenant, channel: channel} do
      conversation = conversation_fixture(tenant, channel)
      activities = for i <- 1..5, do: activity_fixture(tenant, conversation, %{text: "m#{i}"})
      %{conversation: conversation, activities: activities}
    end

    test "page_activities_since pages forward with has_more", %{
      conversation: conversation,
      activities: activities
    } do
      seqs = Enum.map(activities, & &1.seq)

      {page1, true} = Activities.page_activities_since(conversation.id, nil, limit: 2)
      assert Enum.map(page1, & &1.seq) == Enum.take(seqs, 2)

      {page2, true} =
        Activities.page_activities_since(conversation.id, {:seq, List.last(page1).seq}, limit: 2)

      assert Enum.map(page2, & &1.seq) == Enum.slice(seqs, 2, 2)

      {page3, false} =
        Activities.page_activities_since(conversation.id, {:seq, List.last(page2).seq}, limit: 2)

      assert Enum.map(page3, & &1.seq) == [List.last(seqs)]
    end

    test "exactly a full page has no more", %{conversation: conversation} do
      assert {activities, false} = Activities.page_activities_since(conversation.id, nil, limit: 5)
      assert length(activities) == 5
    end

    test "legacy activity id position", %{conversation: conversation, activities: [a1, a2 | _]} do
      {[next], true} =
        Activities.page_activities_since(conversation.id, {:activity_id, a1.id}, limit: 1)

      assert next.id == a2.id
    end

    test "page_recent_activities opens at the end and pages backwards", %{
      conversation: conversation,
      activities: activities
    } do
      seqs = Enum.map(activities, & &1.seq)

      {recent, true} = Activities.page_recent_activities(conversation.id, limit: 2)
      assert Enum.map(recent, & &1.seq) == Enum.take(seqs, -2)

      {older, true} =
        Activities.page_recent_activities(conversation.id,
          limit: 2,
          before_seq: hd(recent).seq
        )

      assert Enum.map(older, & &1.seq) == Enum.slice(seqs, 1, 2)

      {oldest, false} =
        Activities.page_recent_activities(conversation.id, limit: 2, before_seq: hd(older).seq)

      assert Enum.map(oldest, & &1.seq) == [hd(seqs)]
    end

    test "list functions are bounded by the activity max", %{conversation: conversation} do
      put_limits(activity_default_limit: 3, activity_max_limit: 4)
      assert length(Activities.list_activities_for_conversation(conversation.id)) == 3
      assert length(Activities.list_activities_since(conversation.id, nil, limit: 100)) == 4
    end
  end

  describe "audit logs and tenant users" do
    test "paginate_audit_logs walks newest first" do
      logs = for _ <- 1..3, do: audit_log_fixture()

      {:ok, %Page{entries: [_, _] = p1, has_more: true, next_cursor: c}} =
        AuditLogs.paginate_audit_logs(%{}, limit: 2)

      {:ok, %Page{entries: [_] = p2, has_more: false}} =
        AuditLogs.paginate_audit_logs(%{}, limit: 2, cursor: c)

      assert Enum.sort(Enum.map(p1 ++ p2, & &1.id)) == Enum.sort(Enum.map(logs, & &1.id))
    end

    test "list_audit_logs clamps the limit" do
      put_limits(max_limit: 2)
      for _ <- 1..3, do: audit_log_fixture()
      assert length(AuditLogs.list_audit_logs(%{}, limit: 100)) == 2
    end

    test "paginate_tenant_users filters by tenant and preloads tenant", %{tenant: tenant} do
      other = tenant_fixture()

      for {t, i} <- [{tenant, 1}, {tenant, 2}, {other, 3}] do
        {:ok, _} =
          Accounts.create_tenant_user(%{
            tenant_id: t.id,
            name: "User #{i}",
            email: "user#{i}-#{System.unique_integer([:positive])}@example.com",
            password: "password123",
            role: "member"
          })
      end

      {:ok, %Page{entries: users, has_more: false}} =
        Accounts.paginate_tenant_users(%{"tenant_id" => tenant.id})

      assert length(users) == 2
      assert Enum.all?(users, &(&1.tenant.id == tenant.id))

      {:ok, %Page{entries: [_], has_more: true}} = Accounts.paginate_tenant_users(%{}, limit: 1)
    end
  end

  describe "bounded_all/2" do
    test "caps lookup lists" do
      for _ <- 1..3, do: tenant_fixture()
      put_limits(lookup_limit: 2)
      assert length(Converger.Tenants.list_tenants()) == 2
    end
  end
end
