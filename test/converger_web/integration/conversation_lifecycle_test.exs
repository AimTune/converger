defmodule ConvergerWeb.Integration.ConversationLifecycleTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)

    %{tenant: tenant, channel: channel}
  end

  defp bearer(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
  defp api_key(tenant), do: build_conn() |> put_req_header("x-api-key", tenant.api_key)

  test "full end-to-end conversation flow via API", %{tenant: tenant, channel: channel} do
    # 1. Token from the channel secret (normally done by the tenant backend)
    %{"token" => token} =
      channel.secret
      |> bearer()
      |> post(~p"/api/v1/converger/tokens/generate", %{user: %{id: "user-123"}})
      |> json_response(200)

    # 2. Create a conversation; the response carries a conversation token
    %{"conversationId" => conversation_id, "token" => token} =
      token
      |> bearer()
      |> post(~p"/api/v1/converger/conversations")
      |> json_response(201)

    # 3. Post an activity as the end user
    %{"id" => activity_id} =
      token
      |> bearer()
      |> put_req_header("x-idempotency-key", "key-1")
      |> post(~p"/api/v1/converger/conversations/#{conversation_id}/activities", %{
        type: "message",
        text: "Hello from integration test",
        from: %{id: "user-123"}
      })
      |> json_response(200)

    # 4. The end user lists the conversation's activities
    assert %{"activities" => [%{"id" => ^activity_id, "from" => %{"id" => "user-123"}}]} =
             token
             |> bearer()
             |> get(~p"/api/v1/converger/conversations/#{conversation_id}/activities")
             |> json_response(200)

    # 5. The tenant backend sees the same conversation over the tenant API
    assert %{"data" => %{"id" => ^conversation_id, "status" => "active"}} =
             tenant
             |> api_key()
             |> get(~p"/api/v1/conversations/#{conversation_id}")
             |> json_response(200)

    assert %{"data" => [%{"id" => ^activity_id}]} =
             tenant
             |> api_key()
             |> get(~p"/api/v1/conversations/#{conversation_id}/activities")
             |> json_response(200)
  end
end
