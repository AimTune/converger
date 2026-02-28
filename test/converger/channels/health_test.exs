defmodule Converger.Channels.HealthTest do
  use Converger.DataCase

  alias Converger.Channels.Health
  alias Converger.Deliveries

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures
  import Converger.DeliveriesFixtures
  import Converger.HealthCheckFixtures

  setup do
    tenant = tenant_fixture()
    channel = webhook_channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    %{
      tenant: tenant,
      channel: channel,
      conversation: conversation
    }
  end

  describe "compute_channel_health/2" do
    test "returns unknown when no deliveries exist", %{channel: channel} do
      {status, total, failed, rate} = Health.compute_channel_health(channel.id)
      assert status == "unknown"
      assert total == 0
      assert failed == 0
      assert rate == +0.0
    end

    test "returns healthy when failure rate is below 10%", %{
      tenant: tenant,
      channel: channel,
      conversation: conversation
    } do
      # Create 10 deliveries: 0 failed
      for _ <- 1..10 do
        activity = activity_fixture(tenant, conversation)
        delivery = delivery_fixture(activity, channel)
        Deliveries.mark_sent(delivery)
      end

      {status, total, failed, rate} = Health.compute_channel_health(channel.id)
      assert status == "healthy"
      assert total == 10
      assert failed == 0
      assert rate == +0.0
    end

    test "returns degraded when failure rate is between 10% and 50%", %{
      tenant: tenant,
      channel: channel,
      conversation: conversation
    } do
      # Create 10 deliveries: 3 failed (30%)
      for i <- 1..10 do
        activity = activity_fixture(tenant, conversation)
        delivery = delivery_fixture(activity, channel)

        if i <= 3 do
          Deliveries.mark_attempt_failed(delivery, "test error")
          Deliveries.mark_attempt_failed(delivery |> Repo.reload!(), "test error")
          Deliveries.mark_attempt_failed(delivery |> Repo.reload!(), "test error")
          Deliveries.mark_attempt_failed(delivery |> Repo.reload!(), "test error")
          Deliveries.mark_attempt_failed(delivery |> Repo.reload!(), "test error")
        else
          Deliveries.mark_sent(delivery)
        end
      end

      {status, total, failed, rate} = Health.compute_channel_health(channel.id)
      assert status == "degraded"
      assert total == 10
      assert failed == 3
      assert rate == 0.3
    end

    test "returns unhealthy when failure rate exceeds 50%", %{
      tenant: tenant,
      channel: channel,
      conversation: conversation
    } do
      # Create 10 deliveries: 6 failed (60%)
      for i <- 1..10 do
        activity = activity_fixture(tenant, conversation)
        delivery = delivery_fixture(activity, channel)

        if i <= 6 do
          Deliveries.mark_attempt_failed(delivery, "test error")
          Deliveries.mark_attempt_failed(delivery |> Repo.reload!(), "test error")
          Deliveries.mark_attempt_failed(delivery |> Repo.reload!(), "test error")
          Deliveries.mark_attempt_failed(delivery |> Repo.reload!(), "test error")
          Deliveries.mark_attempt_failed(delivery |> Repo.reload!(), "test error")
        else
          Deliveries.mark_sent(delivery)
        end
      end

      {status, total, failed, rate} = Health.compute_channel_health(channel.id)
      assert status == "unhealthy"
      assert total == 10
      assert failed == 6
      assert rate == 0.6
    end
  end

  describe "check_all_channels/1" do
    test "creates health check records for active external channels", %{channel: channel} do
      changes = Health.check_all_channels()
      # First run: no previous status, so no "changes" returned
      assert changes == []

      health = Health.get_latest_health(channel.id)
      assert health != nil
      assert health.status == "unknown"
    end

    test "detects status changes on subsequent runs", %{
      tenant: tenant,
      channel: channel,
      conversation: conversation
    } do
      # First run: unknown (no deliveries)
      Health.check_all_channels()

      # Create some successful deliveries
      for _ <- 1..5 do
        activity = activity_fixture(tenant, conversation)
        delivery = delivery_fixture(activity, channel)
        Deliveries.mark_sent(delivery)
      end

      # Second run: should detect change from unknown to healthy
      changes = Health.check_all_channels()
      assert length(changes) == 1
      [{ch, health_check, previous_status}] = changes
      assert ch.id == channel.id
      assert health_check.status == "healthy"
      assert previous_status == "unknown"
    end

    test "ignores echo and websocket channels" do
      tenant = tenant_fixture()
      echo_channel = channel_fixture(tenant, %{type: "echo", mode: "outbound"})

      changes = Health.check_all_channels()
      assert changes == []

      # No health check records for echo channels
      assert Health.get_latest_health(echo_channel.id) == nil
    end
  end

  describe "get_latest_health_map/1" do
    test "returns map of channel_id to latest health check", %{channel: channel} do
      _h1 =
        health_check_fixture(channel, %{
          status: "healthy",
          checked_at:
            DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
        })

      h2 =
        health_check_fixture(channel, %{
          status: "degraded",
          checked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })

      map = Health.get_latest_health_map([channel.id])
      assert Map.has_key?(map, channel.id)
      assert map[channel.id].id == h2.id
      assert map[channel.id].status == "degraded"
    end

    test "returns empty map for empty input" do
      assert Health.get_latest_health_map([]) == %{}
    end
  end

  describe "list_health_history/2" do
    test "returns recent checks ordered by checked_at desc", %{channel: channel} do
      for i <- 1..5 do
        health_check_fixture(channel, %{
          checked_at:
            DateTime.utc_now() |> DateTime.add(-i, :minute) |> DateTime.truncate(:microsecond)
        })
      end

      history = Health.list_health_history(channel.id, 3)
      assert length(history) == 3
      # Should be ordered most recent first
      [first, second | _] = history
      assert DateTime.compare(first.checked_at, second.checked_at) == :gt
    end
  end

  describe "prune_old_checks/1" do
    test "deletes checks older than specified days", %{channel: channel} do
      # Create an old check (8 days ago) and a recent one
      _old =
        health_check_fixture(channel, %{
          checked_at:
            DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:microsecond)
        })

      _recent =
        health_check_fixture(channel, %{
          checked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })

      assert {:ok, 1} = Health.prune_old_checks(7)
      assert length(Health.list_health_history(channel.id)) == 1
    end
  end
end
