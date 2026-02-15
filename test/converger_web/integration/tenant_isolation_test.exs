defmodule ConvergerWeb.Integration.TenantIsolationTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  alias Converger.Conversations

  setup %{conn: conn} do
    # Tenant A
    tenant_a = tenant_fixture(%{name: "Tenant A"})
    channel_a = channel_fixture(tenant_a)
    content_a = conversation_fixture(tenant_a, channel_a)

    # Tenant B
    tenant_b = tenant_fixture(%{name: "Tenant B"})
    channel_b = channel_fixture(tenant_b)

    # Generate channel token for Tenant B
    {:ok, token_b, _} = Converger.Auth.Token.generate_channel_token(channel_b)

    %{
      conn: conn,
      tenant_a: tenant_a,
      conv_a: content_a,
      tenant_b: tenant_b,
      token_b: token_b
    }
  end

  test "tenant B cannot access tenant A's conversation", %{
    conn: conn,
    conv_a: conv_a,
    tenant_b: tenant_b,
    token_b: token_b
  } do
    # Attempt to GET conversation A using Tenant B's headers
    conn =
      conn
      |> put_req_header("x-tenant-id", tenant_b.id)
      |> put_req_header("x-api-key", tenant_b.api_key)
      |> put_req_header("x-channel-token", token_b)

    # Should return 404. Our implementation catches NoResultsError and returns {:error, :not_found}
    # which FallbackController renders as 404.
    conn = get(conn, ~p"/api/v1/conversations/#{conv_a.id}")
    assert json_response(conn, 404)
  end

  test "tenant B cannot post activity to tenant A's conversation", %{
    conn: conn,
    conv_a: conv_a,
    tenant_b: tenant_b,
    token_b: token_b
  } do
    conn =
      conn
      |> put_req_header("x-tenant-id", tenant_b.id)
      |> put_req_header("x-api-key", tenant_b.api_key)
      |> put_req_header("x-channel-token", token_b)

    conn =
      post(conn, ~p"/api/v1/conversations/#{conv_a.id}/activities", %{
        text: "I am a hacker",
        type: "message"
      })

    assert json_response(conn, 404)
  end
end
