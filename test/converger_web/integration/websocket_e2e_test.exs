defmodule ConvergerWeb.Integration.WebSocketE2ETest do
  use ConvergerWeb.ChannelCase
  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  alias ConvergerWeb.UserSocket
  alias ConvergerWeb.ConversationChannel

  setup %{conn: conn} do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    %{conn: conn, tenant: tenant, channel: channel, conversation: conversation}
  end

  test "complete flow: API token -> WebSocket join -> Broadcast", %{
    conn: conn,
    tenant: tenant,
    channel: channel,
    conversation: conversation
  } do
    # 1. Get Token via API
    # Since TokenController.create needs x-channel-token, we need to generate that first
    # In a real app, the tenant backend generates the channel token.
    # We'll use our internal helper to generate the starter token.
    {:ok, channel_token, _} = Converger.Auth.Token.generate_channel_token(channel)

    token_resp =
      conn
      |> put_req_header("x-channel-token", channel_token)
      |> post(~p"/api/v1/tokens", %{
        conversation_id: conversation.id,
        user_id: "integration-user"
      })
      |> json_response(201)

    assert %{"token" => websocket_token} = token_resp

    # 2. Connect Socket
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => websocket_token})

    # 3. Join Channel
    {:ok, _, socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}")

    # 4. Trigger activity via API and check broadcast
    # Use a separate conn or just call context directly for simplicity in this step,
    # but let's use the API to be "E2E".

    # assert_broadcast "new_activity", %{text: "E2E message"}
    # (No wrapper in broadcast, it uses Map/Struct directly in endpoint broadcast)

    # Wait, the POST activities call returns a wrapped response
    post_resp =
      conn
      |> put_req_header("x-channel-token", websocket_token)
      |> post(~p"/api/v1/conversations/#{conversation.id}/activities", %{
        text: "E2E message",
        type: "message"
      })
      |> json_response(201)

    assert %{"data" => %{"text" => "E2E message"}} = post_resp
    assert_broadcast "new_activity", %{text: "E2E message"}
  end
end
