defmodule ConvergerWeb.ProtocolTokenSecurityTest do
  @moduledoc """
  Token permissions and revocation on the native Protocol v1 WebSocket
  (issue #52, ADR-0059), over a real connection.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Auth.{ConvergerToken, Revocations}
  alias ConvergerWeb.ProtocolClient, as: Client

  @moduletag :protocol

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{channel: channel, conversation: conversation, port: Client.start_server()}
  end

  defp hello(port, token) do
    {:ok, client} = Client.connect(port, headers: [{"authorization", "Bearer #{token}"}])
    Client.push(client, %{"type" => "hello"})
  end

  test "a read-only token receives but cannot send or type", ctx do
    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(ctx.channel, ctx.conversation.id,
        permissions: ["read"]
      )

    client = hello(ctx.port, token)
    {_welcome, client} = Client.recv_type(client, "welcome")

    client =
      Client.push(client, %{"type" => "text", "clientId" => "c-1", "data" => %{"text" => "hi"}})

    assert {%{
              "type" => "error",
              "data" => %{
                "code" => "insufficient_permission",
                "clientId" => "c-1",
                "details" => %{"required" => "write"}
              }
            }, client} = Client.recv(client)

    client = Client.push(client, %{"type" => "typing", "isTyping" => true})

    assert {%{"data" => %{"code" => "insufficient_permission", "frameType" => "typing"}}, client} =
             Client.recv(client)

    Client.close(client)
  end

  test "a token without read is refused with 4403", ctx do
    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(ctx.channel, ctx.conversation.id,
        permissions: ["write"]
      )

    client = hello(ctx.port, token)
    assert {%{"data" => %{"code" => "insufficient_permission"}}, client} = Client.recv(client)
    assert {{:close, 4403}, _client} = Client.recv(client)
  end

  test "a channel-level read-only token cannot start a conversation", ctx do
    {:ok, token, _} = ConvergerToken.generate_token(ctx.channel, permissions: ["read"])

    client = hello(ctx.port, token)
    assert {%{"data" => %{"code" => "insufficient_permission"}}, client} = Client.recv(client)
    assert {{:close, 4403}, _client} = Client.recv(client)
  end

  test "a revoked token draws token_revoked and close 4401", ctx do
    {:ok, token, claims} =
      ConvergerToken.generate_conversation_token(ctx.channel, ctx.conversation.id)

    :ok = Revocations.revoke_family(claims)

    client = hello(ctx.port, token)
    assert {%{"data" => %{"code" => "token_revoked"}}, client} = Client.recv(client)
    assert {{:close, 4401}, _client} = Client.recv(client)
  end

  test "revoking the token of a connected session closes it", ctx do
    {:ok, token, _claims} =
      ConvergerToken.generate_conversation_token(ctx.channel, ctx.conversation.id,
        user_id: "alice"
      )

    client = hello(ctx.port, token)
    {_welcome, client} = Client.recv_type(client, "welcome")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/v1/converger/tokens/revoke")

    assert json_response(conn, 200) == %{"revoked" => "token"}
    assert {{:close, 4403}, _client} = Client.recv(client)
  end
end
