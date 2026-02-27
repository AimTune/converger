defmodule ConvergerWeb.ConversationControllerTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    %{tenant: tenant, channel: channel}
  end

  describe "create conversation" do
    test "creates conversation with valid channel token", %{channel: channel} do
      {:ok, token, _} = Converger.Auth.Token.generate_channel_token(channel)

      conn =
        build_conn()
        |> put_req_header("x-channel-token", token)
        |> post(~p"/api/v1/conversations", %{})

      assert %{"id" => id} = json_response(conn, 201)["data"]
      assert id
    end

    test "renders conversation when data is valid", %{
      conn: conn,
      channel: channel,
      tenant: tenant
    } do
      {:ok, token, _} = Converger.Auth.Token.generate_channel_token(channel)
      conn = conn |> put_req_header("x-channel-token", token)

      params = %{
        "status" => "active",
        "metadata" => %{"custom" => "data"}
      }

      conn = post(conn, ~p"/api/v1/conversations", params)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = recycle(conn)
      conn = conn |> put_req_header("x-api-key", tenant.api_key)
      conn = get(conn, ~p"/api/v1/conversations/#{id}")
      assert json_response(conn, 200)["data"]["id"] == id
      assert json_response(conn, 200)["data"]["tenant_id"] == tenant.id
    end

    test "returns error when channel token is invalid", %{conn: conn, channel: _channel} do
      conn = conn |> put_req_header("x-channel-token", "invalid")
      conn = post(conn, ~p"/api/v1/conversations", %{})
      assert json_response(conn, 401)["errors"]["detail"] == "Unauthorized"
    end
  end

  describe "show conversation" do
    test "returns 404 if conversation belongs to another tenant", %{conn: conn, tenant: tenant} do
      other_tenant = tenant_fixture()
      other_channel = channel_fixture(other_tenant)
      other_conversation = conversation_fixture(other_tenant, other_channel)

      conn = conn |> put_req_header("x-api-key", tenant.api_key)

      conn = get(conn, ~p"/api/v1/conversations/#{other_conversation.id}")
      assert json_response(conn, 404)
    end
  end
end
