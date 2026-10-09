defmodule Converger.PartitionsTest do
  # Creates and detaches partitions (table locks) inside the sandbox.
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.{Activities, Conversations, Deliveries, Partitions}
  alias Converger.Activities.Activity
  alias Converger.Deliveries.Delivery
  alias Converger.Workers.PurgeWorker

  setup do
    tenant = tenant_fixture()
    # Inbound only: the pipeline creates no deliveries, the tests create them.
    channel = channel_fixture(tenant, %{mode: "inbound"})
    conversation = conversation_fixture(tenant, channel)
    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  describe "naming" do
    test "leaf names and months round-trip" do
      assert Partitions.leaf_name("activities", ~D[2026-03-17]) == "activities_p2026_03"
      assert Partitions.parse_leaf_name("deliveries_p2025_12") == {"deliveries", ~D[2025-12-01]}
      assert Partitions.parse_leaf_name("activities_legacy") == :error
      assert Partitions.month_label(~D[2026-03-17]) == "2026-03"
      assert {:ok, ~D[2026-03-01]} = Partitions.parse_month("2026-03")
      assert :error = Partitions.parse_month("2026-13")
      assert Partitions.next_month(~D[2026-12-31]) == ~D[2027-01-01]
    end
  end

  describe "ensure_partitions/1" do
    test "keeps the current month and the months ahead attached" do
      today = Date.utc_today()
      ahead = Date.shift(Partitions.month_start(today), month: 3)

      assert Partitions.ensure_partitions() == []

      for table <- Partitions.tables(), month <- [Partitions.month_start(today), ahead] do
        assert Enum.any?(Partitions.attached(table), &(&1.month == month))
      end
    end

    test "creates missing months with their per-partition unique indexes" do
      month = Date.shift(Partitions.month_start(Date.utc_today()), month: 15)
      leaf = Partitions.leaf_name("activities", month)

      created = Partitions.ensure_partitions(months_ahead: 15)
      assert leaf in created
      assert Partitions.leaf_name("deliveries", month) in created

      indexes =
        Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = $1", [leaf]).rows
        |> List.flatten()

      assert "#{leaf}_conversation_id_seq_index" in indexes
      assert "#{leaf}_conversation_id_idempotency_key_index" in indexes
      # Parent-level indexes are attached automatically.
      assert Enum.any?(indexes, &String.contains?(&1, "tenant_id_id"))

      assert {:ok, :exists} = Partitions.create_partition("activities", month)
    end

    test "never re-attaches a detached month" do
      month = ~D[2024-04-01]
      :ok = Partitions.detach("activities", month)
      assert Enum.any?(Partitions.detached("activities"), &(&1.month == month))
      assert {:error, :detached_exists} = Partitions.create_partition("activities", month)
      assert {:error, :attached} = Partitions.drop_detached("deliveries", month)
      assert :ok = Partitions.drop_detached("activities", month)
      refute Partitions.table_exists?("activities_p2024_04")
    end
  end

  describe "uniqueness across partitions" do
    test "activities land in their month's partition", ctx do
      activity =
        activity_fixture(ctx.tenant, ctx.conversation, %{inserted_at: ~U[2024-06-03 10:00:00Z]})

      assert [["activities_p2024_06"]] =
               Repo.query!("SELECT tableoid::regclass::text FROM activities WHERE id = $1", [
                 Ecto.UUID.dump!(activity.id)
               ]).rows
    end

    test "an idempotency key is honoured when the first copy is in an older partition", ctx do
      attrs = %{
        tenant_id: ctx.tenant.id,
        conversation_id: ctx.conversation.id,
        sender: "user-1",
        text: "hello",
        idempotency_key: "wamid.1"
      }

      {:ok, first} = Activities.create_activity(attrs)

      # Move it to last year's partition, as if the retry arrived much later.
      from(a in Activity, where: a.id == ^first.id)
      |> Repo.update_all(set: [inserted_at: ~U[2025-03-01 00:00:00.000000Z]])

      assert {:ok, again} = Activities.create_activity(attrs)
      assert again.id == first.id

      assert Repo.aggregate(from(a in Activity, where: a.idempotency_key == "wamid.1"), :count) ==
               1
    end

    test "a duplicate (conversation, idempotency key) in one partition is a changeset error",
         ctx do
      attrs = %{
        tenant_id: ctx.tenant.id,
        conversation_id: ctx.conversation.id,
        sender: "user-1",
        idempotency_key: "dup"
      }

      {:ok, _} = Activities.create_activity(attrs)

      # Bypass create_activity's lookups to hit the per-partition index.
      assert {:error, changeset} =
               %Activity{seq: 1000}
               |> Activity.changeset(attrs)
               |> Repo.insert()

      assert {"has already been taken", _} = changeset.errors[:conversation_id]
    end

    test "deliveries copy tenant and partition key from the activity and stay unique", ctx do
      activity =
        activity_fixture(ctx.tenant, ctx.conversation, %{inserted_at: ~U[2024-07-09 08:00:00Z]})

      {:ok, delivery} =
        Deliveries.create_delivery(%{activity_id: activity.id, channel_id: ctx.channel.id})

      assert delivery.tenant_id == ctx.tenant.id
      assert delivery.activity_inserted_at == activity.inserted_at

      assert [["deliveries_p2024_07"]] =
               Repo.query!("SELECT tableoid::regclass::text FROM deliveries WHERE id = $1", [
                 Ecto.UUID.dump!(delivery.id)
               ]).rows

      assert {:error, changeset} =
               Deliveries.create_delivery(%{activity_id: activity.id, channel_id: ctx.channel.id})

      assert {"has already been taken", _} = changeset.errors[:activity_id]

      assert Deliveries.get_or_create_delivery(activity.id, ctx.channel.id).id == delivery.id

      assert {:error, changeset} =
               Deliveries.create_delivery(%{
                 activity_id: Ecto.UUID.generate(),
                 channel_id: ctx.channel.id
               })

      assert {"does not exist", _} = changeset.errors[:activity_id]
    end
  end

  describe "deletes purge partitioned rows (no ON DELETE CASCADE)" do
    setup ctx do
      activity = activity_fixture(ctx.tenant, ctx.conversation)

      {:ok, delivery} =
        Deliveries.create_delivery(%{activity_id: activity.id, channel_id: ctx.channel.id})

      other_tenant = tenant_fixture()
      other_channel = channel_fixture(other_tenant)
      other_conversation = conversation_fixture(other_tenant, other_channel)
      other = activity_fixture(other_tenant, other_conversation)

      Map.merge(ctx, %{activity: activity, delivery: delivery, other: other})
    end

    test "deleting a tenant purges its activities and deliveries", ctx do
      assert {:ok, _} = Converger.Tenants.delete_tenant(ctx.tenant)
      refute Repo.get(Activity, ctx.activity.id)
      refute Repo.get(Delivery, ctx.delivery.id)
      assert Repo.get(Activity, ctx.other.id)
    end

    test "deleting a channel purges its conversations' activities and its deliveries", ctx do
      assert {:ok, _} = Converger.Channels.delete_channel(ctx.channel)
      refute Repo.get(Activity, ctx.activity.id)
      refute Repo.get(Delivery, ctx.delivery.id)
      assert Repo.get(Activity, ctx.other.id)
    end

    test "deleting a conversation purges its activities and their deliveries", ctx do
      assert {:ok, _} = Conversations.delete_conversation(ctx.conversation)
      refute Repo.get(Activity, ctx.activity.id)
      refute Repo.get(Delivery, ctx.delivery.id)
      assert Repo.get(Activity, ctx.other.id)
    end

    test "deleting an activity deletes its deliveries", ctx do
      assert {:ok, _} = Activities.delete_activity(ctx.activity)
      refute Repo.get(Delivery, ctx.delivery.id)
    end

    test "purges run in batches and are idempotent", ctx do
      assert PurgeWorker.purge(%{"tenant_id" => ctx.tenant.id}) == 2
      assert PurgeWorker.purge(%{"tenant_id" => ctx.tenant.id}) == 0

      assert PurgeWorker.conversation_jobs(Enum.map(1..2_500, fn _ -> Ecto.UUID.generate() end))
             |> length() == 3
    end
  end
end
