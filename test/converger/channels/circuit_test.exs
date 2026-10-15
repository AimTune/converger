defmodule Converger.Channels.CircuitTest do
  # Mutates global pipeline/adapter/breaker config, so it cannot run async.
  use Converger.DataCase, async: false
  use Oban.Testing, repo: Converger.Repo

  alias Converger.{Activities, AuditLogs, Channels, Deliveries}
  alias Converger.Channels.{Channel, Circuit}
  alias Converger.Workers.{ActivityDeliveryWorker, ChannelCircuitProbeWorker}

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  setup do
    for key <- [:pipeline, :webhook_req_options, :circuit_breaker] do
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

    Application.put_env(:converger, :circuit_breaker,
      failure_threshold: 3,
      cooldown_ms: 30_000,
      park_seconds: 600
    )

    tenant = tenant_fixture()
    %{tenant: tenant, channel: webhook_channel_fixture(tenant)}
  end

  defp stub_status(status), do: Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, status, "x"))

  defp create_activity(tenant, channel) do
    conversation = conversation_fixture(tenant, channel)

    {:ok, activity} =
      Activities.create_activity(%{
        sender: "user-1",
        text: "hello",
        tenant_id: tenant.id,
        conversation_id: conversation.id
      })

    activity
  end

  defp reload(channel), do: Repo.get!(Channel, channel.id)

  defp delivery(activity, channel),
    do: Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)

  defp job_for(activity) do
    Repo.one!(
      from(j in Oban.Job,
        where: j.worker == ^inspect(ActivityDeliveryWorker),
        where: fragment("?->>'activity_id' = ?", j.args, ^activity.id)
      )
    )
  end

  # Pretend the breaker opened long enough ago for a probe.
  defp age_breaker(channel) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    from(c in Channel, where: c.id == ^channel.id)
    |> Repo.update_all(set: [circuit_changed_at: past])
  end

  defp attach_telemetry(events) do
    ref = make_ref()
    pid = self()

    :telemetry.attach_many(
      "circuit-test-#{inspect(ref)}",
      events,
      fn event, measurements, meta, _ -> send(pid, {:telemetry, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("circuit-test-#{inspect(ref)}") end)
  end

  describe "opening" do
    test "consecutive transient failures open the breaker", %{tenant: tenant, channel: channel} do
      attach_telemetry([[:converger, :channel, :circuit_opened]])
      stub_status(503)

      Oban.Testing.with_testing_mode(:manual, fn ->
        for _ <- 1..3, do: create_activity(tenant, channel)
        assert %{failure: 3} = Oban.drain_queue(queue: :deliveries)
      end)

      assert %{circuit_state: "open", consecutive_failures: 3} = reload(channel)
      assert_received {:telemetry, [:converger, :channel, :circuit_opened], %{count: 1}, meta}
      assert meta.reason == :failures
      assert_enqueued(worker: ChannelCircuitProbeWorker, args: %{channel_id: channel.id})
    end

    test "permanent errors do not count and a success resets the count", %{
      tenant: tenant,
      channel: channel
    } do
      Oban.Testing.with_testing_mode(:manual, fn ->
        stub_status(503)
        for _ <- 1..2, do: create_activity(tenant, channel)
        Oban.drain_queue(queue: :deliveries)
        assert %{consecutive_failures: 2} = reload(channel)

        stub_status(400)
        create_activity(tenant, channel)
        Oban.drain_queue(queue: :deliveries)
        assert %{consecutive_failures: 2, circuit_state: "closed"} = reload(channel)

        stub_status(200)
        create_activity(tenant, channel)
        Oban.drain_queue(queue: :deliveries)
        assert %{consecutive_failures: 0, circuit_state: "closed"} = reload(channel)
      end)
    end

    test "trip/2 opens a closed breaker once", %{channel: channel} do
      assert Circuit.trip(channel, :unhealthy)
      refute Circuit.trip(channel, :unhealthy)
      assert %{circuit_state: "open"} = reload(channel)
    end
  end

  describe "parking" do
    test "an open breaker parks deliveries with a low priority", %{
      tenant: tenant,
      channel: channel
    } do
      attach_telemetry([[:converger, :deliveries, :parked]])
      Circuit.trip(channel, :unhealthy)

      Oban.Testing.with_testing_mode(:manual, fn ->
        activity = create_activity(tenant, channel)
        before = DateTime.utc_now()

        assert %{snoozed: 1} = Oban.drain_queue(queue: :deliveries)

        job = job_for(activity)
        assert job.state == "scheduled"
        assert job.priority == Circuit.parked_priority()
        assert DateTime.diff(job.scheduled_at, before, :second) in 600..661
        assert %{status: "paused", attempts: 0} = delivery(activity, channel)
        assert Circuit.parked_count(channel.id) == 1
      end)

      assert_received {:telemetry, [:converger, :deliveries, :parked], _, %{reason: :open}}
    end

    test "parking never calls the adapter", %{tenant: tenant, channel: channel} do
      Req.Test.stub(__MODULE__, fn _ -> flunk("adapter called while breaker open") end)
      Circuit.trip(channel, :unhealthy)

      Oban.Testing.with_testing_mode(:manual, fn ->
        for _ <- 1..5, do: create_activity(tenant, channel)
        assert %{snoozed: 5} = Oban.drain_queue(queue: :deliveries)
      end)
    end
  end

  describe "half-open probe" do
    test "a successful probe closes the breaker and releases parked jobs", %{
      tenant: tenant,
      channel: channel
    } do
      attach_telemetry([[:converger, :channel, :circuit_closed]])
      Circuit.trip(channel, :unhealthy)

      Oban.Testing.with_testing_mode(:manual, fn ->
        parked = for _ <- 1..3, do: create_activity(tenant, channel)
        assert %{snoozed: 3} = Oban.drain_queue(queue: :deliveries)

        age_breaker(channel)
        stub_status(200)

        # The probe worker wakes one parked job, which claims half_open and succeeds.
        assert {:snooze, _} =
                 perform_job(ChannelCircuitProbeWorker, %{"channel_id" => channel.id})

        assert %{success: 1} = Oban.drain_queue(queue: :deliveries)
        assert %{circuit_state: "closed", consecutive_failures: 0} = reload(channel)

        # Closing released the other two at normal priority, back to pending.
        for activity <- tl(parked) do
          job = job_for(activity)
          assert job.state == "available"
          assert job.priority == 1
          assert %{status: "pending"} = delivery(activity, channel)
        end

        assert %{success: 2} = Oban.drain_queue(queue: :deliveries)
        for activity <- parked, do: assert(%{status: "sent"} = delivery(activity, channel))
      end)

      assert_received {:telemetry, [:converger, :channel, :circuit_closed], _, _}
    end

    test "a failed probe re-opens the breaker", %{channel: channel} do
      Circuit.trip(channel, :unhealthy)
      age_breaker(channel)

      assert :ok = Circuit.admit(reload(channel))
      assert %{circuit_state: "half_open"} = reload(channel)

      # Only one probe at a time.
      assert {:park, :open} = Circuit.admit(reload(channel))

      Circuit.record(reload(channel), {:error, :econnrefused})
      assert %{circuit_state: "open"} = channel = reload(channel)
      assert DateTime.diff(DateTime.utc_now(), channel.circuit_changed_at, :second) < 5
    end

    test "no probe before the cooldown", %{channel: channel} do
      Circuit.trip(channel, :unhealthy)
      assert {:park, :open} = Circuit.admit(reload(channel))

      assert {:snooze, seconds} =
               perform_job(ChannelCircuitProbeWorker, %{"channel_id" => channel.id})

      assert seconds in 25..30
    end

    test "the probe loop stops when nothing is parked or the breaker closed", %{
      channel: channel
    } do
      Circuit.trip(channel, :unhealthy)
      age_breaker(channel)
      assert :ok = perform_job(ChannelCircuitProbeWorker, %{"channel_id" => channel.id})

      Circuit.resume(reload(channel))
      assert :ok = perform_job(ChannelCircuitProbeWorker, %{"channel_id" => channel.id})
    end
  end

  describe "dead-letter replay on close" do
    defp dead_letter(tenant, channel) do
      stub_status(400)
      activity = create_activity(tenant, channel)
      assert %{cancelled: 1} = Oban.drain_queue(queue: :deliveries)
      assert %{status: "failed"} = delivery(activity, channel)
      activity
    end

    defp close_by_probe(channel) do
      Circuit.trip(reload(channel), :unhealthy)
      age_breaker(channel)
      channel = reload(channel)
      assert :ok = Circuit.admit(channel)
      Circuit.record(reload(channel), :ok)
      assert %{circuit_state: "closed"} = reload(channel)
    end

    test "is off by default", %{tenant: tenant, channel: channel} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        dead_letter(tenant, channel)
        close_by_probe(channel)
        refute_enqueued(worker: Converger.Workers.ChannelDeadLetterReplayWorker)
      end)
    end

    test "when enabled, a probe closing the breaker replays recent dead letters", %{
      tenant: tenant,
      channel: channel
    } do
      Application.put_env(:converger, :circuit_breaker,
        replay_dead_letters_on_close: true,
        replay_window_ms: 60_000
      )

      Oban.Testing.with_testing_mode(:manual, fn ->
        activity = dead_letter(tenant, channel)
        close_by_probe(channel)

        assert_enqueued(
          worker: Converger.Workers.ChannelDeadLetterReplayWorker,
          args: %{channel_id: channel.id}
        )

        assert %{success: 1} = Oban.drain_queue(queue: :default)
        assert %{status: "pending", attempts: 0, retry_count: 1} = delivery(activity, channel)
        assert %{retried_by: "system:circuit_breaker"} = delivery(activity, channel)

        stub_status(200)
        assert %{success: 1} = Oban.drain_queue(queue: :deliveries)
        assert %{status: "sent"} = delivery(activity, channel)
      end)
    end

    test "a manual resume does not replay", %{tenant: tenant, channel: channel} do
      Application.put_env(:converger, :circuit_breaker, replay_dead_letters_on_close: true)

      Oban.Testing.with_testing_mode(:manual, fn ->
        dead_letter(tenant, channel)
        Circuit.trip(reload(channel), :unhealthy)
        Channels.resume_deliveries(reload(channel))
        refute_enqueued(worker: Converger.Workers.ChannelDeadLetterReplayWorker)
      end)
    end

    test "replays run in the tenant's tier queue" do
      tenant = tenant_fixture(%{tier: "high"})
      channel = webhook_channel_fixture(tenant)

      Oban.Testing.with_testing_mode(:manual, fn ->
        stub_status(400)
        activity = create_activity(tenant, channel)
        assert %{cancelled: 1} = Oban.drain_queue(queue: :deliveries_high)

        {:ok, _} =
          Deliveries.retry_delivery(delivery(activity, channel), %{type: "admin", id: "x"})

        assert [%{queue: "deliveries_high", state: "available"}] =
                 Repo.all(
                   from(j in Oban.Job,
                     where: j.worker == ^inspect(ActivityDeliveryWorker),
                     where: j.state == "available"
                   )
                 )
      end)
    end
  end

  describe "manual pause/resume" do
    test "pause parks deliveries until resumed; both are audited", %{
      tenant: tenant,
      channel: channel
    } do
      actor = %{type: "admin", id: "ops@example.com"}
      assert {:ok, %{circuit_state: "paused"}} = Channels.pause_deliveries(channel, actor)

      Oban.Testing.with_testing_mode(:manual, fn ->
        activity = create_activity(tenant, channel)
        assert %{snoozed: 1} = Oban.drain_queue(queue: :deliveries)
        assert %{status: "paused"} = delivery(activity, channel)

        # A paused channel is never probed.
        age_breaker(channel)
        assert {:park, :paused} = Circuit.admit(reload(channel))

        stub_status(200)

        assert {:ok, %{circuit_state: "closed"}} =
                 Channels.resume_deliveries(reload(channel), actor)

        assert %{success: 1} = Oban.drain_queue(queue: :deliveries)
        assert %{status: "sent"} = delivery(activity, channel)
      end)

      actions =
        AuditLogs.list_audit_logs(%{resource_id: channel.id})
        |> Enum.map(& &1.action)

      assert "pause_deliveries" in actions
      assert "resume_deliveries" in actions
    end

    test "failures do not close or re-open a paused channel", %{channel: channel} do
      {:ok, channel} = Channels.pause_deliveries(channel)
      for _ <- 1..5, do: Circuit.record(channel, {:error, :timeout})
      assert %{circuit_state: "paused"} = reload(channel)
    end
  end

  describe "rate limit" do
    test "parse_rate_limit/1" do
      assert {:ok, {80, 1_000}} = Circuit.parse_rate_limit("80/s")
      assert {:ok, {1_000, 60_000}} = Circuit.parse_rate_limit("1000/m")
      assert {:ok, {5, 3_600_000}} = Circuit.parse_rate_limit(" 5 / h ")
      assert {:ok, nil} = Circuit.parse_rate_limit(nil)
      assert :error = Circuit.parse_rate_limit("0/s")
      assert :error = Circuit.parse_rate_limit("fast")
      assert :error = Circuit.parse_rate_limit("10/d")
    end

    test "invalid channel rate_limit is rejected", %{tenant: tenant} do
      assert {:error, changeset} =
               Channels.create_channel(%{
                 name: "bad",
                 type: "webhook",
                 tenant_id: tenant.id,
                 config: %{"url" => "https://example.com/hook"},
                 rate_limit: "lots"
               })

      assert %{rate_limit: [_]} = errors_on(changeset)
    end

    test "WhatsApp Meta defaults to 80/s; a channel value wins", %{tenant: tenant} do
      assert Circuit.rate_limit_for(%Channel{type: "whatsapp_meta"}) == {80, 1_000}

      assert Circuit.rate_limit_for(%Channel{type: "whatsapp_meta", rate_limit: "250/s"}) ==
               {250, 1_000}

      assert Circuit.rate_limit_for(webhook_channel_fixture(tenant)) == nil
    end

    test "deliveries over the limit are snoozed, not failed", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{rate_limit: "2/h"})
      stub_status(200)

      Oban.Testing.with_testing_mode(:manual, fn ->
        activities = for _ <- 1..3, do: create_activity(tenant, channel)
        assert %{success: 2, snoozed: 1} = Oban.drain_queue(queue: :deliveries)

        snoozed = Enum.find(activities, &(delivery(&1, channel) == nil))
        job = job_for(snoozed)
        assert job.state == "scheduled"
        # Rate-limited jobs keep their priority; they are not parked.
        assert job.priority == 1
        assert %{consecutive_failures: 0, circuit_state: "closed"} = reload(channel)
      end)
    end
  end

  describe "tenant tiers" do
    test "deliveries go to the queue of the tenant's tier" do
      for {tier, queue} <- [
            {"high", "deliveries_high"},
            {"default", "deliveries"},
            {"bulk", "deliveries_bulk"}
          ] do
        tenant = tenant_fixture(%{tier: tier})
        channel = webhook_channel_fixture(tenant)

        Oban.Testing.with_testing_mode(:manual, fn ->
          activity = create_activity(tenant, channel)
          assert job_for(activity).queue == queue
        end)
      end
    end

    test "unknown tiers are rejected" do
      assert {:error, changeset} = Converger.Tenants.create_tenant(%{name: "x", tier: "vip"})
      assert %{tier: [_]} = errors_on(changeset)
    end
  end
end
