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
      valid_attrs = %{
        name: "some name",
        type: "echo",
        mode: "outbound",
        status: "active",
        tenant_id: tenant.id
      }

      assert {:ok, %Channel{} = channel} = Channels.create_channel(valid_attrs)
      assert channel.name == "some name"
      assert channel.secret != nil
      assert channel.tenant_id == tenant.id
    end

    test "update_channel/2 can regenerate secret", %{tenant: tenant} do
      channel = channel_fixture(tenant)
      old_secret = channel.secret

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

  describe "channel mode" do
    alias Converger.Channels.Channel

    import Converger.TenantsFixtures
    import Converger.ChannelsFixtures

    setup do
      tenant = tenant_fixture()
      %{tenant: tenant}
    end

    test "defaults mode to duplex for webhook", %{tenant: tenant} do
      {:ok, channel} =
        Channels.create_channel(%{
          name: "test-webhook",
          type: "webhook",
          status: "active",
          tenant_id: tenant.id,
          config: %{"url" => "https://example.com"}
        })

      assert channel.mode == "duplex"
    end

    test "echo channel rejects duplex mode", %{tenant: tenant} do
      {:error, changeset} =
        Channels.create_channel(%{
          name: "test-echo",
          type: "echo",
          mode: "duplex",
          status: "active",
          tenant_id: tenant.id
        })

      assert %{mode: [_]} = errors_on(changeset)
    end

    test "echo channel rejects inbound mode", %{tenant: tenant} do
      {:error, changeset} =
        Channels.create_channel(%{
          name: "test-echo",
          type: "echo",
          mode: "inbound",
          status: "active",
          tenant_id: tenant.id
        })

      assert %{mode: [_]} = errors_on(changeset)
    end

    test "echo channel accepts outbound mode", %{tenant: tenant} do
      {:ok, channel} =
        Channels.create_channel(%{
          name: "test-echo",
          type: "echo",
          mode: "outbound",
          status: "active",
          tenant_id: tenant.id
        })

      assert channel.mode == "outbound"
    end

    test "websocket channel only supports outbound", %{tenant: tenant} do
      {:error, changeset} =
        Channels.create_channel(%{
          name: "test-ws",
          type: "websocket",
          mode: "duplex",
          status: "active",
          tenant_id: tenant.id
        })

      assert %{mode: [_]} = errors_on(changeset)

      {:ok, channel} =
        Channels.create_channel(%{
          name: "test-ws",
          type: "websocket",
          mode: "outbound",
          status: "active",
          tenant_id: tenant.id
        })

      assert channel.mode == "outbound"
    end

    test "webhook channel supports all modes", %{tenant: tenant} do
      for mode <- ~w(inbound outbound duplex) do
        {:ok, channel} =
          Channels.create_channel(%{
            name: "test-#{mode}",
            type: "webhook",
            mode: mode,
            status: "active",
            tenant_id: tenant.id,
            config: %{"url" => "https://example.com"}
          })

        assert channel.mode == mode
      end
    end

    test "rejects invalid mode", %{tenant: tenant} do
      {:error, changeset} =
        Channels.create_channel(%{
          name: "test",
          type: "webhook",
          mode: "invalid",
          status: "active",
          tenant_id: tenant.id,
          config: %{"url" => "https://example.com"}
        })

      assert %{mode: [_ | _]} = errors_on(changeset)
    end

    test "list_channels_by_mode/1 filters correctly", %{tenant: tenant} do
      _outbound = channel_fixture(tenant, %{name: "out", type: "echo", mode: "outbound"})

      inbound =
        webhook_channel_fixture(tenant, %{name: "in", mode: "inbound"})

      duplex =
        webhook_channel_fixture(tenant, %{name: "dup", mode: "duplex"})

      inbound_results = Channels.list_channels_by_mode("inbound")
      assert length(inbound_results) == 1
      assert hd(inbound_results).id == inbound.id

      duplex_results = Channels.list_channels_by_mode("duplex")
      assert length(duplex_results) == 1
      assert hd(duplex_results).id == duplex.id
    end

    test "list_inbound_capable_channels/1 returns inbound and duplex", %{tenant: tenant} do
      _outbound = channel_fixture(tenant, %{name: "out", type: "echo", mode: "outbound"})
      _inbound = webhook_channel_fixture(tenant, %{name: "in", mode: "inbound"})
      _duplex = webhook_channel_fixture(tenant, %{name: "dup", mode: "duplex"})

      results = Channels.list_inbound_capable_channels(tenant.id)
      assert length(results) == 2
      modes = Enum.map(results, & &1.mode) |> Enum.sort()
      assert modes == ["duplex", "inbound"]
    end

    test "list_outbound_capable_channels/1 returns outbound and duplex", %{tenant: tenant} do
      _outbound = channel_fixture(tenant, %{name: "out", type: "echo", mode: "outbound"})
      _inbound = webhook_channel_fixture(tenant, %{name: "in", mode: "inbound"})
      _duplex = webhook_channel_fixture(tenant, %{name: "dup", mode: "duplex"})

      results = Channels.list_outbound_capable_channels(tenant.id)
      assert length(results) == 2
      modes = Enum.map(results, & &1.mode) |> Enum.sort()
      assert modes == ["duplex", "outbound"]
    end
  end
end
