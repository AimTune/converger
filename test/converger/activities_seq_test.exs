defmodule Converger.ActivitiesSeqTest do
  use Converger.DataCase, async: false

  alias Converger.Activities
  alias Converger.Activities.Activity
  alias Converger.ConvergerAPI.Watermark
  alias Ecto.Adapters.SQL.Sandbox

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  defp attrs(conversation, text) do
    %{
      sender: "user-1",
      text: text,
      tenant_id: conversation.tenant_id,
      conversation_id: conversation.id
    }
  end

  describe "concurrent inserts" do
    # Real concurrency needs real connections: the SQL sandbox would funnel
    # every process through one connection and serialize them. Data is
    # committed for real and cleaned up afterwards.
    @tag timeout: 120_000
    test "N concurrent inserts into one conversation get seq 1..N, no gaps or duplicates" do
      {tenant, conversation} =
        Sandbox.unboxed_run(Repo, fn ->
          tenant = tenant_fixture()
          channel = channel_fixture(tenant)
          {tenant, conversation_fixture(tenant, channel)}
        end)

      on_exit(fn -> cleanup(tenant) end)

      for n <- [1, 7, 25] do
        start = Sandbox.unboxed_run(Repo, fn -> Repo.reload!(conversation).last_seq end)

        seqs =
          1..n
          |> Task.async_stream(
            fn i ->
              Sandbox.unboxed_run(Repo, fn ->
                {:ok, activity} = Activities.create_activity(attrs(conversation, "msg #{i}"))
                activity.seq
              end)
            end,
            max_concurrency: n,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, seq} -> seq end)
          |> Enum.sort()

        assert seqs == Enum.to_list((start + 1)..(start + n))
      end
    end

    defp cleanup(tenant) do
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(l in Converger.AuditLogs.AuditLog, where: l.tenant_id == ^tenant.id))
        # Cascades to channels and conversations; activities are purged by
        # the (inline) PurgeWorker job it enqueues.
        {:ok, _} = Converger.Tenants.delete_tenant(tenant)
      end)
    end
  end

  describe "ordering and watermarks" do
    setup do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      %{conversation: conversation_fixture(tenant, channel), tenant: tenant}
    end

    test "seq is per conversation", %{conversation: conversation, tenant: tenant} do
      other = conversation_fixture(tenant, channel_fixture(tenant))

      {:ok, a} = Activities.create_activity(attrs(conversation, "a"))
      {:ok, b} = Activities.create_activity(attrs(other, "b"))
      {:ok, c} = Activities.create_activity(attrs(conversation, "c"))

      assert {a.seq, b.seq, c.seq} == {1, 1, 2}
    end

    test "a rejected insert does not burn a seq", %{conversation: conversation} do
      {:ok, _} =
        Activities.create_activity(attrs(conversation, "one") |> Map.put(:idempotency_key, "k"))

      # Same idempotency key: returns the existing activity, no new seq.
      {:ok, _} =
        Activities.create_activity(attrs(conversation, "dup") |> Map.put(:idempotency_key, "k"))

      # Invalid type: rejected before a seq is allocated.
      {:error, _} =
        Activities.create_activity(attrs(conversation, "bad") |> Map.put(:type, "bogus"))

      {:ok, two} = Activities.create_activity(attrs(conversation, "two"))
      assert two.seq == 2
    end

    test "watermark replay returns exactly the activities after it, including same-microsecond inserts",
         %{conversation: conversation, tenant: tenant} do
      same_instant = ~U[2026-01-01 12:00:00.000000Z]

      [a1, a2, a3, a4] =
        for text <- ~w(a1 a2 a3 a4),
            do: activity_fixture(tenant, conversation, %{text: text, inserted_at: same_instant})

      {:ok, position} = Watermark.decode(Watermark.encode(a2.seq))
      assert position == {:seq, a2.seq}

      assert Enum.map(Activities.list_activities_since(conversation.id, position), & &1.id) ==
               [a3.id, a4.id]

      # Every possible watermark returns exactly the tail after it.
      all = [a1, a2, a3, a4]

      for {wm, index} <- Enum.with_index(all) do
        expected = Enum.drop(all, index + 1) |> Enum.map(& &1.id)
        got = Activities.list_activities_since(conversation.id, {:seq, wm.seq})
        assert Enum.map(got, & &1.id) == expected
      end
    end

    test "legacy activity-id watermarks are still accepted", %{
      conversation: conversation,
      tenant: tenant
    } do
      a1 = activity_fixture(tenant, conversation, %{text: "a1"})
      a2 = activity_fixture(tenant, conversation, %{text: "a2"})

      legacy = Base.url_encode64(a1.id, padding: false)
      assert {:ok, {:activity_id, id}} = Watermark.decode(legacy)
      assert id == a1.id

      assert [%Activity{id: a2_id}] =
               Activities.list_activities_since(conversation.id, {:activity_id, id})

      assert a2_id == a2.id
    end

    test "invalid watermarks are rejected" do
      assert {:error, :invalid_watermark} = Watermark.decode("!!!")
      assert {:error, :invalid_watermark} = Watermark.decode(Base.url_encode64("seq:abc"))
      assert {:error, :invalid_watermark} = Watermark.decode(Base.url_encode64("not-a-uuid"))
      assert {:ok, nil} = Watermark.decode(nil)
    end
  end

  describe "migration backfill" do
    test "numbers existing rows per conversation by (inserted_at, id)", %{} do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      c1 = conversation_fixture(tenant, channel)
      c2 = conversation_fixture(tenant, channel)

      t0 = ~U[2025-01-01 00:00:00.000000Z]

      ids =
        for {conv, offset, text} <- [{c1, 2, "c1-late"}, {c1, 0, "c1-early"}, {c2, 1, "c2"}] do
          activity =
            activity_fixture(tenant, conv, %{text: text, inserted_at: DateTime.add(t0, offset)})

          {text, activity.id}
        end
        |> Map.new()

      # Simulate pre-migration data: no seq, counters reset.
      Repo.query!("ALTER TABLE activities ALTER COLUMN seq DROP NOT NULL")
      Repo.query!("UPDATE activities SET seq = NULL WHERE tenant_id = $1", [dump(tenant.id)])
      Repo.query!("UPDATE conversations SET last_seq = 0 WHERE tenant_id = $1", [dump(tenant.id)])

      run_backfill()

      seq = fn text -> Repo.get!(Activity, ids[text]).seq end
      assert seq.("c1-early") == 1
      assert seq.("c1-late") == 2
      assert seq.("c2") == 1
      assert Repo.reload!(c1).last_seq == 2
      assert Repo.reload!(c2).last_seq == 1

      # Changes are rolled back with the sandbox transaction.
      Repo.query!("ALTER TABLE activities ALTER COLUMN seq SET NOT NULL")
    end

    defp dump(uuid), do: Ecto.UUID.dump!(uuid)

    @migration Converger.Repo.Migrations.AddSeqToActivities

    # Run the migration's own backfill statements against the current rows.
    defp run_backfill do
      unless Code.ensure_loaded?(@migration) do
        Code.require_file("priv/repo/migrations/20261008150000_add_seq_to_activities.exs")
      end

      # apply/3: the migration module is only loaded at runtime, so a direct
      # call would be a compile-time "undefined module" warning.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      @migration |> apply(:backfill_statements, []) |> Enum.each(&Repo.query!/1)
    end
  end
end
