defmodule ConvergerWeb.ActivityIdempotencyTest do
  use ConvergerWeb.ConnCase, async: false

  alias Converger.Repo
  alias Converger.Activities.Activity

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  setup %{conn: conn} do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    # Authenticate
    conn =
      conn
      |> put_req_header("x-api-key", tenant.api_key)

    %{conn: conn, tenant: tenant, conversation: conversation}
  end

  test "prevents duplicate activities via x-idempotency-key", %{
    conn: conn,
    conversation: conversation
  } do
    params = %{
      "type" => "message",
      "sender" => "user-1",
      "text" => "hello world"
    }

    idempotency_key = "test-key-123"

    # First request
    conn1 =
      conn
      |> put_req_header("x-idempotency-key", idempotency_key)
      |> post(~p"/api/v1/conversations/#{conversation.id}/activities", params)

    assert %{"data" => %{"id" => id1}} = json_response(conn1, 201)

    # Second request with same key
    conn2 =
      build_conn()
      |> put_req_header("x-api-key", conn.req_headers |> List.keyfind("x-api-key", 0) |> elem(1))
      |> put_req_header("x-idempotency-key", idempotency_key)
      |> post(~p"/api/v1/conversations/#{conversation.id}/activities", params)

    assert %{"data" => %{"id" => id2}} = json_response(conn2, 201)
    assert id1 == id2

    # Verify only one activity exists in DB
    assert Repo.aggregate(Activity, :count) == 1
  end

  test "allows different activities with different keys", %{
    conn: conn,
    conversation: conversation
  } do
    params = %{"sender" => "user-1", "text" => "h1"}

    post(
      conn |> put_req_header("x-idempotency-key", "k1"),
      ~p"/api/v1/conversations/#{conversation.id}/activities",
      params
    )

    post(
      conn |> put_req_header("x-idempotency-key", "k2"),
      ~p"/api/v1/conversations/#{conversation.id}/activities",
      params
    )

    assert Repo.aggregate(Activity, :count) == 2
  end
end
