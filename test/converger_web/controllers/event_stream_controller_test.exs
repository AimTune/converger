defmodule ConvergerWeb.ConvergerAPI.EventStreamControllerTest do
  @moduledoc """
  The Server-Sent Events fallback
  (`GET /api/v1/converger/conversations/:id/events`) over a real connection.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Channels}
  alias Converger.Auth.ConvergerToken
  alias ConvergerWeb.ProtocolClient, as: Client

  @moduletag :protocol

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    {:ok, token, _} = ConvergerToken.generate_conversation_token(channel, conversation.id)

    %{
      tenant: tenant,
      channel: channel,
      conversation: conversation,
      token: token,
      path: "/api/v1/converger/conversations/#{conversation.id}/events"
    }
  end

  defp activity!(conversation, text) do
    {:ok, activity} =
      Activities.create_activity(%{
        "type" => "message",
        "text" => text,
        "sender" => "bot-1",
        "tenant_id" => conversation.tenant_id,
        "conversation_id" => conversation.id
      })

    activity
  end

  defp open(ctx, query, headers \\ []) do
    port = Client.start_server()
    headers = [{"authorization", "Bearer #{ctx.token}"} | headers]
    {200, client} = Client.sse_connect(port, ctx.path <> query, headers)
    client
  end

  test "replays after the watermark, then streams live activities", ctx do
    activity!(ctx.conversation, "one")
    activity!(ctx.conversation, "two")

    client = open(ctx, "?watermark=1")

    assert {%{id: "2", frame: %{"type" => "text", "seq" => 2, "data" => %{"text" => "two"}}},
            client} = Client.sse_recv(client)

    activity!(ctx.conversation, "three")

    assert {%{id: "3", frame: %{"seq" => 3, "data" => %{"text" => "three"}}}, _client} =
             Client.sse_recv(client)
  end

  test "Last-Event-ID wins over ?watermark= on reconnect", ctx do
    for text <- ~w(one two three), do: activity!(ctx.conversation, text)

    client = open(ctx, "?watermark=0", [{"last-event-id", "2"}])
    assert {%{id: "3"}, client} = Client.sse_recv(client)
    assert {:timeout, _client} = Client.sse_recv(client, 200)
  end

  test "without a watermark the whole conversation is replayed", ctx do
    activity!(ctx.conversation, "one")
    client = open(ctx, "")
    assert {%{id: "1"}, _client} = Client.sse_recv(client)
  end

  test "accepts the token in the query string (EventSource)", ctx do
    activity!(ctx.conversation, "one")
    port = Client.start_server()
    {200, client} = Client.sse_connect(port, ctx.path <> "?token=#{ctx.token}")
    assert {%{id: "1"}, _client} = Client.sse_recv(client)
  end

  test "sends heartbeats", ctx do
    Application.put_env(:converger, ConvergerWeb.Protocol, heartbeat_interval_ms: 1_000)
    on_exit(fn -> Application.delete_env(:converger, ConvergerWeb.Protocol) end)

    client = open(ctx, "")
    assert {%{id: nil, frame: %{"type" => "heartbeat"}}, _client} = Client.sse_recv(client, 1_500)
  end

  test "ends with channel_inactive when the channel is deactivated", ctx do
    client = open(ctx, "")
    {:ok, channel} = Channels.update_channel(ctx.channel, %{status: "inactive"})
    ConvergerWeb.Sockets.disconnect_channel(channel.id)

    assert {%{frame: %{"type" => "error", "data" => %{"code" => "channel_inactive"}}}, client} =
             Client.sse_recv(client)

    assert {:done, _client} = Client.sse_recv(client)

    # The connection process outlives the stream (keep-alive): it must not
    # stay tracked as a connected client.
    assert ConvergerWeb.Sockets.count(channel.id) == 0
  end

  test "is tracked as a connection of the channel while open", ctx do
    _client = open(ctx, "")
    assert ConvergerWeb.Sockets.count(ctx.channel.id) == 1
  end

  describe "refused requests" do
    test "without a token: 401", %{conn: conn, path: path} do
      assert conn |> get(path) |> json_response(401)
    end

    test "a token for another conversation: 403", ctx do
      other = conversation_fixture(ctx.tenant, ctx.channel)
      {:ok, token, _} = ConvergerToken.generate_conversation_token(ctx.channel, other.id)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(ctx.path)

      assert json_response(conn, 403)
    end

    test "a conversation of another channel: 404", ctx do
      other_channel = channel_fixture(ctx.tenant)
      other = conversation_fixture(ctx.tenant, other_channel)
      {:ok, token, _} = ConvergerToken.generate_token(ctx.channel)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/converger/conversations/#{other.id}/events")

      assert json_response(conn, 404)
    end
  end
end
