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

  # All tokens share one signer; only the channel token may act as the tenant.
  describe "end-user tokens as x-channel-token" do
    setup %{tenant: tenant, channel: channel, conversation: conversation} do
      {:ok, conversation_token, _} = Token.generate_token(conversation, tenant, "user-1")

      {:ok, converger_token, _} =
        Converger.Auth.ConvergerToken.generate_conversation_token(channel, conversation.id,
          user_id: "user-1"
        )

      %{end_user_tokens: [conversation_token, converger_token]}
    end

    test "are rejected by tenant-authenticated routes", %{
      conn: conn,
      conversation: conversation,
      end_user_tokens: tokens
    } do
      for token <- tokens do
        conn = put_req_header(conn, "x-channel-token", token)

        assert json_response(get(conn, ~p"/api/v1/routing_rules"), 401)["error"] ==
                 "Unauthorized: Invalid token"

        assert json_response(get(conn, ~p"/api/v1/conversations/#{conversation.id}"), 401)
      end
    end

    test "cannot mint conversation tokens or create conversations", %{
      conn: conn,
      tenant: tenant,
      channel: channel,
      end_user_tokens: tokens
    } do
      other_conversation = conversation_fixture(tenant, channel)

      for token <- tokens do
        conn = put_req_header(conn, "x-channel-token", token)

        assert json_response(
                 post(conn, ~p"/api/v1/tokens", %{
                   "conversation_id" => other_conversation.id,
                   "user_id" => "someone-else"
                 }),
                 401
               )

        assert json_response(post(conn, ~p"/api/v1/conversations", %{}), 401)
      end
    end
  end
end
