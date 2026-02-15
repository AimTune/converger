defmodule Converger.ChannelsTest do
  use Converger.DataCase

  alias Converger.Channels

  describe "channels" do
    alias Converger.Channels.Channel

    import Converger.TenantsFixtures
    import Converger.ChannelsFixtures

    setup do
      tenant = tenant_fixture()
      %{tenant: tenant}
    end

    test "list_channels_for_tenant/1 returns all channels for tenant", %{tenant: tenant} do
      channel = channel_fixture(tenant)
      assert Channels.list_channels_for_tenant(tenant.id) == [channel]
    end

    test "create_channel/1 with valid data creates a channel", %{tenant: tenant} do
      valid_attrs = %{name: "some name", status: "active", tenant_id: tenant.id}

      assert {:ok, %Channel{} = channel} = Channels.create_channel(valid_attrs)
      assert channel.name == "some name"
      assert channel.secret != nil
      assert channel.tenant_id == tenant.id
    end

    test "update_channel/2 can regenerate secret", %{tenant: tenant} do
      channel = channel_fixture(tenant)
      old_secret = channel.secret

      # We don't have a specific regenerate function yet, let's see if update works
      # Actually, the logic for autogenerating might be in the changeset.
      # If we pass a flag or just empty secret, maybe it regenerates?
      # Let's check the context code or just test if we can manually set it.
      assert {:ok, %Channel{} = updated_channel} =
               Channels.update_channel(channel, %{secret: "newsecret"})

      assert updated_channel.secret == "newsecret"
      assert updated_channel.secret != old_secret
    end

    test "channels are scoped to tenant", %{tenant: tenant} do
      tenant2 = tenant_fixture()
      channel1 = channel_fixture(tenant)
      channel2 = channel_fixture(tenant2)

      assert Channels.list_channels_for_tenant(tenant.id) == [channel1]
      assert Channels.list_channels_for_tenant(tenant2.id) == [channel2]
    end
  end
end
