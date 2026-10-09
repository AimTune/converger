defmodule Converger.DeliveriesRetryTest do
  # Mutates global pipeline/adapter config, so it cannot run async.
  use Converger.DataCase, async: false
  use Oban.Testing, repo: Converger.Repo

  alias Converger.{Activities, AuditLogs, Channels, Deliveries}
  alias Converger.Activities.Activity
  alias Converger.Deliveries.Delivery
  alias Converger.Workers.ActivityDeliveryWorker

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  @actor %{type: "admin", id: "ops@example.com"}

  setup do
    for key <- [:pipeline, :webhook_req_options] do
      previous = Application.get_env(:converger, key)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:converger, key, previous),
          else: Application.delete_env(:converger, key)
      end)
    end

    Application.put_env(:converger, :pipeline, backend: Converger.Pipeline.Oban)

    Application.put_env(:converger, :webhook_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    tenant = tenant_fixture()
    %{tenant: tenant, channel: webhook_channel_fixture(tenant)}
  end

  # `n` dead letters on `channel`, inserted directly (activities live on a
  # websocket conversation, so creating them enqueues nothing).
  defp dead_letters(tenant, channel, n, attrs \\ %{}) do
    conversation = conversation_fixture(tenant, channel_fixture(tenant))
    now = DateTime.utc_now()

    activities =
      for seq <- 1..n do
        %{
          id: Ecto.UUID.generate(),
          type: "message",
          sender: "user-1",
          text: "hello #{seq}",
          attachments: [],
          metadata: %{"api_key" => "sk-secret"},
          seq: seq,
          tenant_id: tenant.id,
          conversation_id: conversation.id,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Activity, activities)

    deliveries =
      for activity <- activities do
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            activity_id: activity.id,
            channel_id: channel.id,
            status: "failed",
            attempts: 5,
            last_error: "HTTP 500",
            retry_count: 0,
            metadata: %{},
            inserted_at: now,
            updated_at: now
          },
          attrs
        )
      end

    Repo.insert_all(Delivery, deliveries)
    Enum.map(deliveries, &Repo.get!(Delivery, &1.id))
  end

  defp delivery_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == ^inspect(ActivityDeliveryWorker)))
  end

  describe "retry_delivery/2" do
    test "resets a dead letter, records who retried it and enqueues one job",
         %{tenant: tenant, channel: channel} do
      [dead] = dead_letters(tenant, channel, 1)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, retried} = Deliveries.retry_delivery(dead, @actor)

        assert %{status: "pending", attempts: 0, retry_count: 1} = retried
        assert retried.retried_by == "admin:ops@example.com"
        assert retried.retried_at

        assert_enqueued(
          worker: ActivityDeliveryWorker,
          args: %{activity_id: dead.activity_id, channel_id: channel.id}
        )
      end)

      assert [log] = AuditLogs.list_audit_logs(%{resource_type: "delivery"})
      assert %{action: "retry", actor_type: "admin", tenant_id: tid} = log
      assert tid == tenant.id
      assert log.resource_id == dead.id
      assert log.changes["before"]["status"] == "failed"
    end

    test "refuses deliveries that are not failed", %{tenant: tenant, channel: channel} do
      [sent] = dead_letters(tenant, channel, 1, %{status: "sent"})
      assert {:error, :not_failed} = Deliveries.retry_delivery(sent, @actor)
    end

    test "refuses deliveries on an inactive channel", %{tenant: tenant, channel: channel} do
      [dead] = dead_letters(tenant, channel, 1)
      {:ok, _} = Channels.update_channel(channel, %{status: "inactive"})
      assert {:error, :channel_inactive} = Deliveries.retry_delivery(dead, @actor)
    end

    test "a stale struct retried twice is replayed only once", %{tenant: tenant, channel: channel} do
      [dead] = dead_letters(tenant, channel, 1)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, _} = Deliveries.retry_delivery(dead, @actor)
        assert {:error, :not_failed} = Deliveries.retry_delivery(dead, @actor)
        assert length(delivery_jobs()) == 1
      end)
    end

    test "replays a delivery whose earlier job completed (failed by a provider receipt)",
         %{tenant: tenant, channel: channel} do
      [dead] = dead_letters(tenant, channel, 1)

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, job} =
          %{activity_id: dead.activity_id, channel_id: channel.id}
          |> ActivityDeliveryWorker.new()
          |> Oban.insert()

        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])

        assert {:ok, _} = Deliveries.retry_delivery(dead, @actor)
        assert length(delivery_jobs()) == 2
      end)
    end

    test "a failed webhook delivery ends sent after fixing the URL and retrying",
         %{tenant: tenant, channel: channel} do
      Req.Test.stub(__MODULE__, fn conn ->
        if conn.request_path == "/fixed",
          do: Plug.Conn.send_resp(conn, 200, "ok"),
          else: Plug.Conn.send_resp(conn, 404, "no such hook")
      end)

      conversation = conversation_fixture(tenant, channel)

      {:ok, activity} =
        Activities.create_activity(%{
          sender: "user-1",
          text: "hello",
          tenant_id: tenant.id,
          conversation_id: conversation.id
        })

      dead = Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)
      assert %{status: "failed", last_error: error} = dead
      assert error =~ "404"

      {:ok, _} =
        Channels.update_channel(channel, %{config: %{"url" => "https://example.com/fixed"}})

      assert {:ok, _} = Deliveries.retry_delivery(dead, @actor)

      assert %{status: "sent", attempts: 1, retry_count: 1} = Repo.get!(Delivery, dead.id)
    end
  end

  describe "retry_dead_letters/3" do
    test "bulk retry of 1000 dead letters enqueues 1000 jobs without duplicates",
         %{tenant: tenant, channel: channel} do
      dead = dead_letters(tenant, channel, 1000)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{retried: 1000, has_more: false}} =
                 Deliveries.retry_dead_letters(%{channel_id: channel.id}, @actor)

        # A second call finds nothing left to replay.
        assert {:ok, %{retried: 0}} =
                 Deliveries.retry_dead_letters(%{channel_id: channel.id}, @actor)

        jobs = delivery_jobs()
        assert length(jobs) == 1000

        assert jobs |> Enum.map(& &1.args["activity_id"]) |> Enum.uniq() |> length() == 1000
        assert MapSet.new(jobs, & &1.args["activity_id"]) == MapSet.new(dead, & &1.activity_id)
      end)

      assert Repo.aggregate(from(d in Delivery, where: d.status == "pending"), :count) == 1000
      assert AuditLogs.count_audit_logs(%{resource_type: "delivery", action: "retry"}) == 1000
    end

    test "respects :limit and reports what is left", %{tenant: tenant, channel: channel} do
      dead_letters(tenant, channel, 5)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{retried: 3, has_more: true}} =
                 Deliveries.retry_dead_letters(%{channel_id: channel.id}, @actor, limit: 3)

        assert {:ok, %{retried: 2, has_more: false}} =
                 Deliveries.retry_dead_letters(%{channel_id: channel.id}, @actor, limit: 3)
      end)
    end

    test "only touches the tenant's failed deliveries in the time window",
         %{tenant: tenant, channel: channel} do
      [old] = dead_letters(tenant, channel, 1, %{updated_at: ~U[2026-01-01 00:00:00.000000Z]})
      [recent] = dead_letters(tenant, channel, 1)
      [sent] = dead_letters(tenant, channel, 1, %{status: "sent"})

      other = tenant_fixture()
      [foreign] = dead_letters(other, webhook_channel_fixture(other), 1)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{retried: 1}} =
                 Deliveries.retry_dead_letters(
                   %{tenant_id: tenant.id, from: ~U[2026-06-01 00:00:00Z]},
                   @actor
                 )
      end)

      assert Repo.get!(Delivery, recent.id).status == "pending"
      assert Repo.get!(Delivery, old.id).status == "failed"
      assert Repo.get!(Delivery, sent.id).status == "sent"
      assert Repo.get!(Delivery, foreign.id).status == "failed"
    end

    test "skips inactive channels", %{tenant: tenant, channel: channel} do
      dead_letters(tenant, channel, 2)
      {:ok, _} = Channels.update_channel(channel, %{status: "inactive"})

      assert {:ok, %{retried: 0, has_more: false}} =
               Deliveries.retry_dead_letters(%{tenant_id: tenant.id}, @actor)
    end
  end

  describe "search_deliveries/2 and payload_preview/1" do
    test "scopes by tenant and redacts secrets in the payload", %{
      tenant: tenant,
      channel: channel
    } do
      [dead] = dead_letters(tenant, channel, 1)
      other = tenant_fixture()
      dead_letters(other, webhook_channel_fixture(other), 1)

      {:ok, page} =
        Deliveries.search_deliveries(%{tenant_id: tenant.id, status: "failed"},
          preload: [:activity]
        )

      assert [%{id: id} = delivery] = page.entries
      assert id == dead.id

      payload = Deliveries.payload_preview(delivery)
      assert payload.text == "hello 1"
      assert payload.metadata["api_key"] == "[REDACTED]"
    end
  end

  describe "cast_filters/1" do
    test "casts and validates params" do
      channel_id = Ecto.UUID.generate()

      assert {:ok, %{status: "failed", channel_id: ^channel_id, from: from, to: to}} =
               Deliveries.cast_filters(%{
                 "status" => "failed",
                 "channel_id" => channel_id,
                 "from" => "2026-10-01",
                 "to" => "2026-10-02",
                 "activity_id" => ""
               })

      assert from == ~U[2026-10-01 00:00:00.000000Z]
      assert to == ~U[2026-10-02 23:59:59.999999Z]

      assert {:ok, %{from: ~U[2026-10-01 12:00:00Z]}} =
               Deliveries.cast_filters(%{"from" => "2026-10-01T12:00:00Z"})

      assert {:error, "Invalid status"} = Deliveries.cast_filters(%{"status" => "bogus"})
      assert {:error, "Invalid channel_id"} = Deliveries.cast_filters(%{"channel_id" => "x"})
      assert {:error, "Invalid to"} = Deliveries.cast_filters(%{"to" => "yesterday"})
    end
  end
end
