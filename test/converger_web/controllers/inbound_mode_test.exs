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
        build_conn()
        |> put_req_header("x-converger-signature", "")
        |> post(~p"/api/v1/channels/#{channel.id}/inbound", %{"text" => "hello", "sender" => "user1"})

      assert json_response(conn, 400)["error"] =~ "inbound"
    end

    test "accepts inbound to duplex channel", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "duplex"})

      conn =
        build_conn()
        |> post(~p"/api/v1/channels/#{channel.id}/inbound", %{"text" => "hello", "sender" => "user1"})

      assert json_response(conn, 201)["status"] == "accepted"
    end

    test "accepts inbound to inbound-only channel", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "inbound"})

      conn =
        build_conn()
        |> post(~p"/api/v1/channels/#{channel.id}/inbound", %{"text" => "hello", "sender" => "user1"})

      assert json_response(conn, 201)["status"] == "accepted"
    end
  end
end
