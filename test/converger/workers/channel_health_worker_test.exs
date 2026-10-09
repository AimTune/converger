defmodule Converger.Workers.ChannelHealthWorkerTest do
  use Converger.DataCase

  alias Converger.Channels.Health
  alias Converger.Workers.ChannelHealthWorker

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  setup do
    tenant = tenant_fixture()
    channel = webhook_channel_fixture(tenant)

    %{tenant: tenant, channel: channel}
  end

  describe "perform/1" do
    test "creates health check records for active channels", %{channel: channel} do
      assert :ok = ChannelHealthWorker.perform(%Oban.Job{})

      health = Health.get_latest_health(channel.id)
      assert health != nil
      assert health.status == "unknown"
      assert health.channel_id == channel.id
    end

    test "succeeds with no active channels" do
      # Delete all channels
      Converger.Repo.delete_all(Converger.Channels.Channel)
      assert :ok = ChannelHealthWorker.perform(%Oban.Job{})
    end

    test "turning unhealthy opens the delivery circuit breaker", %{
      tenant: tenant,
      channel: channel
    } do
      Converger.HealthCheckFixtures.health_check_fixture(channel, %{
        checked_at: DateTime.add(DateTime.utc_now(), -300, :second)
      })

      conversation = Converger.ConversationsFixtures.conversation_fixture(tenant, channel)

      for _ <- 1..3, do: Converger.ActivitiesFixtures.activity_fixture(tenant, conversation)

      import Ecto.Query

      Converger.Repo.update_all(
        from(d in Converger.Deliveries.Delivery, where: d.channel_id == ^channel.id),
        set: [status: "failed"]
      )

      assert :ok = ChannelHealthWorker.perform(%Oban.Job{})

      assert %{circuit_state: "open"} =
               Converger.Repo.get!(Converger.Channels.Channel, channel.id)
    end

    test "creates records on each run", %{channel: channel} do
      assert :ok = ChannelHealthWorker.perform(%Oban.Job{})
      assert :ok = ChannelHealthWorker.perform(%Oban.Job{})

      history = Health.list_health_history(channel.id)
      assert length(history) == 2
    end
  end
end
