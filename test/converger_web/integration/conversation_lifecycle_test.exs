defmodule ConvergerWeb.Integration.ConversationLifecycleTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  alias Converger.Conversations
  alias Converger.Activities

  setup %{conn: conn} do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)

    # Base connection with x-tenant-id
    conn = put_req_header(conn, "x-tenant-id", tenant.id)
    conn = put_req_header(conn, "x-api-key", tenant.api_key)

    %{conn: conn, tenant: tenant, channel: channel}
  end

  test "full end-to-end conversation flow via API", %{
    conn: conn,
    tenant: tenant,
    channel: channel
  } do
    # 1. Generate Channel Token (Normally done by tenant backend)
    {:ok, channel_token, _} = Converger.Auth.Token.generate_channel_token(channel)

    # 2. Create Conversation using Channel Token
    conn = put_req_header(conn, "x-channel-token", channel_token)

    conv_resp =
      conn
      |> post(~p"/api/v1/conversations", %{
        metadata: %{"subject" => "Support request"}
      })
      |> json_response(201)

    assert %{"data" => %{"id" => conversation_id, "status" => "active"}} = conv_resp

    # 3. Generate Activity Token using Channel Token + Conversation ID
    token_resp =
      conn
      |> post(~p"/api/v1/tokens", %{
        conversation_id: conversation_id,
        user_id: "user-123"
      })
      |> json_response(201)

    assert %{"token" => activity_token} = token_resp

    # 4. Post Activity using Activity Token
    # ActivityController uses TenantAuth which checks either API Key + Tenant ID OR valid activity token.
    # Our activity token contains tenant_id and conversation_id.
    conn =
      conn
      |> delete_req_header("x-channel-token")
      |> put_req_header("x-channel-token", activity_token)

    activity_resp =
      conn
      |> post(~p"/api/v1/conversations/#{conversation_id}/activities", %{
        type: "message",
        text: "Hello from integration test",
        idempotency_key: "key-1"
      })
      |> json_response(201)

    assert %{"data" => %{"id" => activity_id, "text" => "Hello from integration test"}} =
             activity_resp

    # 5. List Activities
    list_resp =
      conn
      |> get(~p"/api/v1/conversations/#{conversation_id}/activities")
      |> json_response(200)

    assert %{"data" => [%{"id" => ^activity_id}]} = list_resp
  end
end
