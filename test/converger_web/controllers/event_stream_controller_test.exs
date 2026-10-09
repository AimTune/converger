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

  describe "signals and draining" do
    setup ctx do
      on_exit(&ConvergerWeb.Drain.reset/0)

      {:ok, bob_token, _} =
        ConvergerToken.generate_conversation_token(ctx.channel, ctx.conversation.id,
          user_id: "bob"
        )

      %{token: bob_token}
    end

    test "typing and read receipts of other participants are streamed", ctx do
      client = open(ctx, "")
      alice = ConvergerWeb.ConversationSignals.participant(%{"user_id" => "alice"})
      activity!(ctx.conversation, "one")
      {%{id: "1"}, client} = Client.sse_recv(client)

      # As if Alice typed on a WebSocket of the same conversation.
      ConvergerWeb.Endpoint.broadcast!(
        ConvergerWeb.ConversationSignals.topic(ctx.conversation.id),
        "typing",
        %{participant: alice, is_typing: true}
      )

      assert {%{id: nil, frame: %{"type" => "typing", "isTyping" => true}}, client} =
               Client.sse_recv(client)

      {:ok, 1} = ConvergerWeb.ConversationSignals.read(ctx.conversation.id, alice, 1)

      assert {%{frame: %{"type" => "deliveryStatus", "data" => %{"upToSeq" => 1}}}, _} =
               Client.sse_recv(client)
    end

    test "an identified viewer is online for presence while the stream is open", ctx do
      _client = open(ctx, "")
      topic = ConvergerWeb.ConversationPresence.topic(ctx.conversation.id)
      assert %{"bob" => _} = ConvergerWeb.ConversationPresence.list(topic)
    end

    test "draining ends the stream with unavailable", ctx do
      client = open(ctx, "")
      ConvergerWeb.ProtocolConnections.drain()

      assert {%{frame: %{"type" => "error", "data" => %{"code" => "unavailable"} = data}}, client} =
               Client.sse_recv(client)

      assert data["retryAfterMs"] > 0
      assert {:done, _} = Client.sse_recv(client)
      assert ConvergerWeb.ProtocolConnections.count() == 0
    end

    test "new streams are refused with 503 while the node drains", ctx do
      ConvergerWeb.Drain.start_draining()
      port = Client.start_server()

      assert {503, _} =
               Client.sse_connect(port, ctx.path, [{"authorization", "Bearer #{ctx.token}"}])
    end
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
