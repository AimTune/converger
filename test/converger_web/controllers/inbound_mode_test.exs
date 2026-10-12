defmodule ConvergerWeb.InboundModeTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  setup do
    tenant = tenant_fixture()
    %{tenant: tenant}
  end

  describe "inbound mode enforcement" do
    test "rejects inbound to outbound-only channel", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "outbound"})

      conn =
        signed_post(build_conn(), ~p"/api/v1/channels/#{channel.id}/inbound", channel, %{
          "text" => "hello",
          "sender" => "user1"
        })

      assert assert_api_error(conn, 400, "inbound_not_supported")["message"] =~ "inbound"
    end

    test "accepts inbound to duplex channel", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "duplex"})

      conn =
        signed_post(build_conn(), ~p"/api/v1/channels/#{channel.id}/inbound", channel, %{
          "text" => "hello",
          "sender" => "user1"
        })

      assert json_response(conn, 201)["status"] == "accepted"
    end

    test "accepts inbound to inbound-only channel", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "inbound"})

      conn =
        signed_post(build_conn(), ~p"/api/v1/channels/#{channel.id}/inbound", channel, %{
          "text" => "hello",
          "sender" => "user1"
        })

      assert json_response(conn, 201)["status"] == "accepted"
    end

    test "rejects an inbound message without text or attachments with 422", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "inbound"})

      conn =
        signed_post(build_conn(), ~p"/api/v1/channels/#{channel.id}/inbound", channel, %{
          "sender" => "user1"
        })

      assert assert_api_error(conn, 422, "invalid_message")["message"] =~ "no text"
    end
  end
end
