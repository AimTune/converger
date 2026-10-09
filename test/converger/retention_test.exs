defmodule Converger.RetentionTest do
  # Detaching partitions takes table locks inside the sandbox transaction.
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.Activities.Activity
  alias Converger.Archive
  alias Converger.Archive.Part
  alias Converger.Deliveries
  alias Converger.Deliveries.Delivery
  alias Converger.Partitions
  alias Converger.Retention

  @moduletag :capture_log

  @month ~D[2025-01-01]

  setup do
    dir =
      Path.join(System.tmp_dir!(), "converger_archive_test_#{System.unique_integer([:positive])}")

    original = Application.get_env(:converger, Converger.Archive)

    set_storage(dir, nil)

    on_exit(fn ->
      Application.put_env(:converger, Converger.Archive, original)
      File.rm_rf!(dir)
    end)

    short = tenant_fixture(%{retention_days: 30})
    long = tenant_fixture(%{retention_days: 365})

    %{dir: dir, short: seed(short, 3), long: seed(long, 2)}
  end

  defp set_storage(dir, fail) do
    Application.put_env(:converger, Converger.Archive,
      storage: Converger.FlakyStorage,
      storage_opts: [dir: dir, fail: fail],
      prefix: "archive",
      part_rows: 2
    )
  end

  # `n` activities of a tenant in @month, each with one delivery.
  defp seed(tenant, n) do
    # Inbound only: the pipeline creates no deliveries, seed/2 creates them.
    channel = channel_fixture(tenant, %{mode: "inbound"})
    conversation = conversation_fixture(tenant, channel)

    activities =
      for i <- 1..n do
        activity =
          activity_fixture(tenant, conversation, %{
            text: "old #{i}",
            inserted_at: DateTime.add(~U[2025-01-10 10:00:00.000000Z], i, :minute)
          })

        {:ok, _} = Deliveries.create_delivery(%{activity_id: activity.id, channel_id: channel.id})
        activity
      end

    %{tenant: tenant, channel: channel, activities: activities}
  end

  defp count(schema, tenant_id),
    do: Repo.aggregate(from(r in schema, where: r.tenant_id == ^tenant_id), :count)

  defp leaf_attached?(table, month),
    do: Enum.any?(Partitions.attached(table), &(&1.month == month))

  test "candidate months end at least min_retention_days ago" do
    months = Retention.candidate_months(~D[2025-03-10])
    assert @month in months
    # February ended on 2025-03-01, only 9 days before.
    refute ~D[2025-02-01] in months
    assert Enum.all?(months, &(Date.compare(&1, ~D[2025-02-01]) == :lt))
  end

  test "expired?/3 compares the end of the month with the retention" do
    assert Retention.expired?(@month, 30, ~D[2025-03-03])
    refute Retention.expired?(@month, 30, ~D[2025-03-02])
    # The platform minimum wins over a smaller value.
    refute Retention.expired?(@month, 1, ~D[2025-02-05])
  end

  test "a tenant whose retention ended first is archived and deleted from the live partition",
       %{short: short, long: long, dir: dir} do
    assert {:ok, [result]} = Retention.run(today: ~D[2025-04-15], months: [@month])
    assert result.action == :tenant_rows_archived
    assert result.tenants == [short.tenant.id]
    assert result.rows == 6

    # Short tenant's rows are gone, the long tenant's are untouched and the
    # partition is still attached.
    assert count(Activity, short.tenant.id) == 0
    assert count(Delivery, short.tenant.id) == 0
    assert count(Activity, long.tenant.id) == 2
    assert count(Delivery, long.tenant.id) == 2
    assert leaf_attached?("activities", @month)

    # 3 activities in parts of 2 rows, 3 deliveries likewise.
    parts = Archive.parts(@month, tenant_id: short.tenant.id)

    assert Enum.map(parts, &{&1.table_name, &1.part, &1.row_count, &1.mode}) == [
             {"activities", 1, 2, "deleted"},
             {"activities", 2, 1, "deleted"},
             {"deliveries", 1, 2, "deleted"},
             {"deliveries", 2, 1, "deleted"}
           ]

    assert Enum.all?(parts, & &1.verified_at)

    key = "archive/#{short.tenant.id}/2025-01/activities-00001.jsonl.gz"
    assert Enum.any?(parts, &(&1.object_key == key))
    body = File.read!(Path.join(dir, key))
    lines = body |> :zlib.gunzip() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert [%{"text" => "old " <> _, "seq" => _, "tenant_id" => tid} | _] = lines
    assert tid == short.tenant.id
  end

  test "when every tenant expired the month is detached, archived, verified and dropped",
       %{short: short, long: long} do
    # First the short tenant alone, then everyone.
    {:ok, _} = Retention.run(today: ~D[2025-04-15], months: [@month])
    assert {:ok, [result]} = Retention.run(today: ~D[2026-02-15], months: [@month])

    assert result.action == :partition_dropped
    assert result.rows == %{"activities" => 2, "deliveries" => 2}
    refute leaf_attached?("activities", @month)
    refute leaf_attached?("deliveries", @month)
    refute Partitions.table_exists?(Partitions.leaf_name("activities", @month))
    refute Partitions.table_exists?(Partitions.leaf_name("deliveries", @month))

    detached = Archive.parts(@month, tenant_id: long.tenant.id, mode: "detached")

    assert Enum.map(detached, &{&1.table_name, &1.row_count}) == [
             {"activities", 2},
             {"deliveries", 2}
           ]

    assert Enum.all?(detached, & &1.verified_at)

    # The archive can be re-imported (the partition is recreated).
    original_ids = Enum.map(short.activities, & &1.id) |> Enum.sort()

    assert {:ok, %{"activities" => %{parts: 2, rows: 3, inserted: 3}, "deliveries" => %{rows: 3}}} =
             Archive.import_tenant_month(short.tenant.id, @month)

    assert {:ok, %{"activities" => %{rows: 2, inserted: 2}}} =
             Archive.import_tenant_month(long.tenant.id, @month)

    assert leaf_attached?("activities", @month)

    imported = Repo.all(from(a in Activity, where: a.tenant_id == ^short.tenant.id))
    assert Enum.map(imported, & &1.id) |> Enum.sort() == original_ids

    original = hd(short.activities)
    reimported = Repo.get!(Activity, original.id)
    assert reimported.text == original.text
    assert reimported.seq == original.seq
    assert reimported.inserted_at == original.inserted_at
    assert reimported.metadata == original.metadata
    assert count(Delivery, short.tenant.id) == 3

    # Importing again changes nothing.
    assert {:ok, %{"activities" => %{inserted: 0}, "deliveries" => %{inserted: 0}}} =
             Archive.import_tenant_month(short.tenant.id, @month)
  end

  test "nothing is deleted or dropped when the upload fails, and a later run resumes",
       %{short: short, long: long, dir: dir} do
    set_storage(dir, :put)

    assert {:error, {:upload_failed, _, :simulated_outage}} =
             Retention.run(today: ~D[2025-04-15], months: [@month])

    assert count(Activity, short.tenant.id) == 3
    assert Repo.aggregate(Part, :count) == 0

    # Whole month: detached first, then the upload fails. The data stays in
    # the detached table, invisible to the application but not lost.
    assert {:error, {:upload_failed, _, _}} =
             Retention.run(today: ~D[2026-02-15], months: [@month])

    refute leaf_attached?("activities", @month)
    assert Partitions.table_exists?(Partitions.leaf_name("activities", @month))

    assert [[5]] =
             Repo.query!("SELECT count(*) FROM #{Partitions.leaf_name("activities", @month)}").rows

    # The detached month is picked up first on the next run.
    set_storage(dir, nil)
    assert @month in Retention.candidate_months(~D[2026-02-15])

    assert {:ok, [%{action: :partition_dropped}]} =
             Retention.run(today: ~D[2026-02-15], months: [@month])

    refute Partitions.table_exists?(Partitions.leaf_name("activities", @month))

    assert Archive.parts(@month, table: "activities") |> Enum.map(& &1.row_count) |> Enum.sum() ==
             5

    assert long.tenant.id in (Archive.parts(@month) |> Enum.map(& &1.tenant_id))
  end

  test "a checksum mismatch keeps the partition", %{dir: dir} do
    set_storage(dir, :corrupt_get)

    assert {:error, {:checksum_mismatch, _}} =
             Retention.run(today: ~D[2026-02-15], months: [@month])

    assert Partitions.table_exists?(Partitions.leaf_name("activities", @month))
  end

  test "an empty expired month is dropped" do
    month = ~D[2024-02-01]
    assert leaf_attached?("activities", month)

    assert {:ok, [%{action: :partition_dropped, rows: %{"activities" => 0}}]} =
             Retention.run(today: ~D[2026-02-15], months: [month])

    refute Partitions.table_exists?(Partitions.leaf_name("activities", month))
  end

  test "tenants_in/1 lists the distinct tenants of a partition", %{short: short, long: long} do
    assert Retention.tenants_in(Partitions.leaf_name("activities", @month)) ==
             Enum.sort([short.tenant.id, long.tenant.id])
  end

  describe "prune/1" do
    test "deletes health checks and audit logs outside their windows" do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      now = DateTime.utc_now()

      for days <- [1, 10] do
        Repo.insert!(%Converger.Channels.HealthCheck{
          channel_id: channel.id,
          status: "healthy",
          checked_at: DateTime.add(now, -days, :day)
        })
      end

      for days <- [1, 400] do
        Repo.insert!(%Converger.AuditLogs.AuditLog{
          actor_type: "admin",
          actor_id: "a",
          action: "update",
          resource_type: "tenant",
          resource_id: tenant.id,
          inserted_at: DateTime.add(now, -days, :day)
        })
      end

      assert %{channel_health_checks: 1, audit_logs: 1} =
               Retention.prune(health_check_days: 7, audit_log_days: 365)

      assert Repo.aggregate(Converger.Channels.HealthCheck, :count) == 1

      # Disabled windows prune nothing.
      assert %{channel_health_checks: nil, audit_logs: nil} =
               Retention.prune(health_check_days: 0, audit_log_days: nil)
    end
  end

  test "tenants cannot go below the platform minimum" do
    assert {:error, changeset} =
             Converger.Tenants.create_tenant(%{name: "x", retention_days: 7})

    assert %{retention_days: [_]} = errors_on(changeset)
    assert {:ok, tenant} = Converger.Tenants.create_tenant(%{name: "y"})
    assert tenant.retention_days == 365
  end
end
