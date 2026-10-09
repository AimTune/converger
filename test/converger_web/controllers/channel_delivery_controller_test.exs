defmodule ConvergerWeb.ChannelDeliveryControllerTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  setup %{conn: conn} do
    tenant = tenant_fixture()
    channel = webhook_channel_fixture(tenant, %{rate_limit: "80/s"})
    %{conn: put_req_header(conn, "x-api-key", tenant.api_key), tenant: tenant, channel: channel}
  end

  test "shows the delivery state", %{conn: conn, channel: channel} do
    data = conn |> get(~p"/api/v1/channels/#{channel.id}/delivery") |> json_response(200)

    assert %{
             "channel_id" => id,
             "circuit_state" => "closed",
             "consecutive_failures" => 0,
             "rate_limit" => %{"limit" => 80, "scale_ms" => 1000},
             "parked_deliveries" => 0
           } = data["data"]

    assert id == channel.id
  end

  test "pauses and resumes deliveries", %{conn: conn, tenant: tenant, channel: channel} do
    conn = post(conn, ~p"/api/v1/channels/#{channel.id}/pause")
    assert json_response(conn, 200)["data"]["circuit_state"] == "paused"

    conn = conn |> recycle() |> put_req_header("x-api-key", tenant.api_key)
    conn = post(conn, ~p"/api/v1/channels/#{channel.id}/resume")
    assert json_response(conn, 200)["data"]["circuit_state"] == "closed"
  end

  test "another tenant's channel is not found", %{conn: conn} do
    other = webhook_channel_fixture(tenant_fixture())

    assert_error_sent 404, fn -> post(conn, ~p"/api/v1/channels/#{other.id}/pause") end
  end

  test "requires the tenant API key", %{channel: channel} do
    conn = post(build_conn(), ~p"/api/v1/channels/#{channel.id}/pause")
    assert conn.status == 401
  end
end
