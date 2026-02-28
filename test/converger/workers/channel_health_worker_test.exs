defmodule Converger.Workers.ChannelHealthWorkerTest do
  use Converger.DataCase

  alias Converger.Workers.ChannelHealthWorker
  alias Converger.Channels.Health

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

    test "creates records on each run", %{channel: channel} do
      assert :ok = ChannelHealthWorker.perform(%Oban.Job{})
      assert :ok = ChannelHealthWorker.perform(%Oban.Job{})

      history = Health.list_health_history(channel.id)
      assert length(history) == 2
    end
  end
end
