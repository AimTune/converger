defmodule ConvergerWeb.AuthenticationTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Auth.Token

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    {:ok, channel_token, _} = Token.generate_channel_token(channel)
    %{tenant: tenant, conversation: conversation, channel: channel, channel_token: channel_token}
  end

  describe "Tenant API Key Auth" do
    test "returns 401 if missing header on protected route", %{
      conn: conn,
      conversation: conversation
    } do
      # GET /api/v1/conversations/:id is protected by TenantAuth
      conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}")
      assert json_response(conn, 401)["error"] == "Unauthorized: Missing authentication headers"
    end

    test "returns 401 if invalid api key on protected route", %{
      conn: conn,
      conversation: conversation
    } do
      conn = conn |> put_req_header("x-api-key", "invalid")
      conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}")
      assert json_response(conn, 401)["error"] == "Unauthorized: Invalid or inactive API Key"
    end
  end

  describe "Token Issuance (via Channel Token)" do
    test "generates user token for valid channel token", %{
      conn: conn,
      conversation: conversation,
      channel_token: channel_token
    } do
      conn = conn |> put_req_header("x-channel-token", channel_token)

      params = %{
        "conversation_id" => conversation.id,
        "user_id" => "user-123"
      }

      conn = post(conn, ~p"/api/v1/tokens", params)
      response = json_response(conn, 201)
      assert response["token"] != nil
      assert response["expires_in"] == 3600
    end

    test "returns 401 if missing channel token", %{conn: conn, conversation: conversation} do
      params = %{
        "conversation_id" => conversation.id,
        "user_id" => "user-123"
      }

      conn = post(conn, ~p"/api/v1/tokens", params)
      assert json_response(conn, 400)["error"] == "Missing x-channel-token header"
    end

    test "returns forbidden if channel token does not match conversation", %{
      conn: conn,
      tenant: tenant,
      channel_token: channel_token
    } do
      # Create another channel for same tenant
      other_channel = channel_fixture(tenant)
      other_conversation = conversation_fixture(tenant, other_channel)

      # Using channel_token for first channel to access second channel's conversation
      conn = conn |> put_req_header("x-channel-token", channel_token)

      params = %{
        "conversation_id" => other_conversation.id,
        "user_id" => "user-123"
      }

      conn = post(conn, ~p"/api/v1/tokens", params)
      assert json_response(conn, 403)["errors"]["detail"] == "Forbidden"
    end
  end
end
