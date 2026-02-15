defmodule ConvergerWeb.ActivityControllerTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{tenant: tenant, conversation: conversation}
  end

  describe "create activity" do
    test "renders activity when data is valid", %{
      conn: conn,
      tenant: tenant,
      conversation: conversation
    } do
      conn = conn |> put_req_header("x-api-key", tenant.api_key)

      params = %{
        "type" => "message",
        "sender" => "user-1",
        "text" => "hello world",
        "idempotency_key" => "uniq-1"
      }

      conn = post(conn, ~p"/api/v1/conversations/#{conversation.id}/activities", params)
      assert %{"id" => id} = json_response(conn, 201)["data"]
      assert id != nil
      assert json_response(conn, 201)["data"]["text"] == "hello world"
      assert json_response(conn, 201)["data"]["tenant_id"] == tenant.id
    end

    test "returns 404 when conversation belongs to another tenant", %{conn: conn, tenant: tenant} do
      other_tenant = tenant_fixture()
      other_channel = channel_fixture(other_tenant)
      other_conversation = conversation_fixture(other_tenant, other_channel)

      conn = conn |> put_req_header("x-api-key", tenant.api_key)

      params = %{"sender" => "user-1", "text" => "hi"}
      conn = post(conn, ~p"/api/v1/conversations/#{other_conversation.id}/activities", params)
      assert json_response(conn, 404)
    end
  end

  describe "index activities" do
    test "lists activities for conversation", %{
      conn: conn,
      tenant: tenant,
      conversation: conversation
    } do
      activity = activity_fixture(tenant, conversation)

      conn = conn |> put_req_header("x-api-key", tenant.api_key)
      conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}/activities")

      data = json_response(conn, 200)["data"]
      assert length(data) == 1
      assert hd(data)["id"] == activity.id
    end

    test "returns 404 if conversation belongs to another tenant", %{conn: conn, tenant: tenant} do
      other_tenant = tenant_fixture()
      other_channel = channel_fixture(other_tenant)
      other_conversation = conversation_fixture(other_tenant, other_channel)

      conn = conn |> put_req_header("x-api-key", tenant.api_key)
      conn = get(conn, ~p"/api/v1/conversations/#{other_conversation.id}/activities")
      assert json_response(conn, 404)
    end
  end
end
