defmodule ConvergerWeb.ProtocolSocketTest do
  @moduledoc """
  The native Converger Protocol v1 WebSocket (`/socket/converger/v1`) over a
  real connection. Every server frame is validated against the protocol's
  JSON Schema by `ConvergerWeb.ProtocolClient`.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Channels, Conversations, Repo}
  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias ConvergerWeb.ProtocolClient, as: Client

  @moduletag :protocol

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    port = Client.start_server()

    %{tenant: tenant, channel: channel, conversation: conversation, port: port}
  end

  defp token(channel, conversation, opts \\ []) do
    {:ok, token, _claims} =
      ConvergerToken.generate_conversation_token(channel, conversation.id, opts)

    token
  end

  defp activity!(conversation, text, sender \\ "bot-1") do
    {:ok, activity} =
      Activities.create_activity(%{
        "type" => "message",
        "text" => text,
        "sender" => sender,
        "tenant_id" => conversation.tenant_id,
        "conversation_id" => conversation.id
      })

    activity
  end

  # Connect and complete the handshake; returns {welcome, client}.
  defp join(port, token, hello \\ %{}, opts \\ []) do
    {:ok, client} =
      Client.connect(
        port,
        Keyword.put_new(opts, :headers, [{"authorization", "Bearer #{token}"}])
      )

    client = Client.push(client, Map.merge(%{"type" => "hello"}, hello))
    {welcome, client} = Client.recv(client)
    assert %{"type" => "welcome"} = welcome
    {welcome, client}
  end

  describe "upgrade" do
    test "selects the first supported subprotocol the client offers", ctx do
      {:ok, client} =
        Client.connect(ctx.port, subprotocols: ["chat", "converger.v1", "converger.v1+msgpack"])

      assert Client.subprotocol(client) == "converger.v1"
      Client.close(client)
    end

    test "accepts clients that offer no subprotocol (mekik/1)", ctx do
      {:ok, client} = Client.connect(ctx.port)
      assert Client.subprotocol(client) == nil
      Client.close(client)
    end

    test "refuses clients that offer only unsupported subprotocols", ctx do
      assert {:error, 400} = Client.connect(ctx.port, subprotocols: ["converger.v2"])
    end

    test "answers a plain GET with 426 Upgrade Required", %{conn: conn} do
      conn = get(conn, "/socket/converger/v1")
      assert json_response(conn, 426)["error"] =~ "WebSocket"
    end
  end

  describe "handshake" do
    test "welcome describes the session and replays after the watermark", ctx do
      first = activity!(ctx.conversation, "one")
      _second = activity!(ctx.conversation, "two")
      _third = activity!(ctx.conversation, "three")

      token = token(ctx.channel, ctx.conversation, user_id: "alice")
      {welcome, client} = join(ctx.port, token, %{"watermark" => first.seq})

      assert %{
               "protocol" => "converger/1",
               "compat" => ["mekik/1"],
               "conversationId" => conversation_id,
               "userId" => "alice",
               "watermark" => 3,
               "scope" => "conversation",
               "capabilities" => %{"acks" => true}
             } = welcome["data"]

      assert conversation_id == ctx.conversation.id

      {two, client} = Client.recv(client)
      {three, client} = Client.recv(client)

      assert %{"type" => "text", "seq" => 2, "from" => "bot", "data" => %{"text" => "two"}} = two
      assert %{"type" => "text", "seq" => 3, "data" => %{"text" => "three"}} = three
      Client.refute_frame(client)
    end

    test "without a watermark the whole conversation is replayed", ctx do
      activity!(ctx.conversation, "one")
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      assert {%{"seq" => 1}, _client} = Client.recv(client)
    end

    test "accepts the legacy opaque watermark", ctx do
      first = activity!(ctx.conversation, "one")
      activity!(ctx.conversation, "two")
      legacy = Converger.ConvergerAPI.Watermark.encode(first.seq)

      {_welcome, client} =
        join(ctx.port, token(ctx.channel, ctx.conversation), %{"watermark" => legacy})

      assert {%{"seq" => 2}, _client} = Client.recv(client)
    end

    test "a watermark above the head draws invalid_watermark and no replay", ctx do
      activity!(ctx.conversation, "one")

      {_welcome, client} =
        join(ctx.port, token(ctx.channel, ctx.conversation), %{"watermark" => 99})

      assert {%{"type" => "error", "data" => %{"code" => "invalid_watermark"}}, client} =
               Client.recv(client)

      Client.refute_frame(client)
    end

    test "the token may come from hello.token", ctx do
      {:ok, client} = Client.connect(ctx.port)
      token = token(ctx.channel, ctx.conversation)
      client = Client.push(client, %{"type" => "hello", "token" => token})
      assert {%{"type" => "welcome"}, _client} = Client.recv(client)
    end

    test "the token may come from the query string", ctx do
      token = token(ctx.channel, ctx.conversation)
      {:ok, client} = Client.connect(ctx.port, path: "/socket/converger/v1?token=#{token}")
      client = Client.push(client, %{"type" => "hello"})
      assert {%{"type" => "welcome"}, _client} = Client.recv(client)
    end

    test "a channel-level token adopts an asserted conversation of its channel", ctx do
      {:ok, token, _} = ConvergerToken.generate_token(ctx.channel)

      {welcome, _client} =
        join(ctx.port, token, %{"conversationId" => ctx.conversation.id})

      assert welcome["data"]["conversationId"] == ctx.conversation.id
    end

    test "a channel-level token starts a new conversation otherwise", ctx do
      other_channel = channel_fixture(ctx.tenant)
      foreign = conversation_fixture(ctx.tenant, other_channel)
      {:ok, token, _} = ConvergerToken.generate_token(ctx.channel, user_id: "bob")

      {welcome, _client} = join(ctx.port, token, %{"conversationId" => foreign.id})

      new_id = welcome["data"]["conversationId"]
      assert new_id != foreign.id

      assert %{channel_id: channel_id, metadata: %{"user_id" => "bob"}} =
               Conversations.get_conversation(new_id)

      assert channel_id == ctx.channel.id
    end

    test "an invalid token draws unauthorized and close 4401", ctx do
      {:ok, client} = Client.connect(ctx.port, headers: [{"authorization", "Bearer nope"}])
      client = Client.push(client, %{"type" => "hello"})

      assert {%{"type" => "error", "data" => %{"code" => "unauthorized"}}, client} =
               Client.recv(client)

      assert {{:close, 4401}, _client} = Client.recv(client)
    end

    test "an inactive channel draws channel_inactive and close 4403", ctx do
      token = token(ctx.channel, ctx.conversation)
      {:ok, _} = Channels.update_channel(ctx.channel, %{status: "inactive"})

      {:ok, client} = Client.connect(ctx.port, headers: [{"authorization", "Bearer #{token}"}])
      client = Client.push(client, %{"type" => "hello"})

      assert {%{"data" => %{"code" => "channel_inactive"}}, client} = Client.recv(client)
      assert {{:close, 4403}, _client} = Client.recv(client)
    end

    test "an unknown protocol version closes with 4400", ctx do
      {:ok, client} = Client.connect(ctx.port)
      client = Client.push(client, %{"type" => "hello", "protocol" => "converger/9"})

      assert {%{"data" => %{"code" => "unsupported_protocol"}}, client} = Client.recv(client)
      assert {{:close, 4400}, _client} = Client.recv(client)
    end

    test "frames before hello draw no_session", ctx do
      {:ok, client} = Client.connect(ctx.port)
      client = Client.push(client, %{"type" => "ping"})

      assert {%{"data" => %{"code" => "no_session", "frameType" => "ping"}}, _client} =
               Client.recv(client)
    end
  end

  describe "sending" do
    test "a text frame with a clientId is persisted once and acked", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation, user_id: "alice"))
      frame = %{"type" => "text", "clientId" => "c-1", "data" => %{"text" => "hi"}}

      client = Client.push(client, frame)
      {ack, client} = Client.recv(client)
      assert %{"type" => "ack", "clientId" => "c-1", "seq" => 1, "id" => id} = ack
      refute Map.has_key?(ack, "duplicate")

      client = Client.push(client, frame)
      {again, client} = Client.recv(client)
      assert %{"type" => "ack", "clientId" => "c-1", "seq" => 1, "id" => ^id} = again
      assert again["duplicate"] == true

      assert [%Activity{text: "hi", sender: "alice", idempotency_key: "c-1"}] = Repo.all(Activity)
      # Echo rule: the sending connection does not get its own turn back.
      Client.refute_frame(client)
    end

    test "other connections receive the turn with the acked seq", ctx do
      {_welcome, alice} = join(ctx.port, token(ctx.channel, ctx.conversation, user_id: "alice"))
      {_welcome, tab} = join(ctx.port, token(ctx.channel, ctx.conversation, user_id: "alice"))
      {_welcome, agent} = join(ctx.port, token(ctx.channel, ctx.conversation, user_id: "agent-7"))

      alice =
        Client.push(alice, %{
          "type" => "text",
          "clientId" => "c-9",
          "data" => %{"text" => "hello"}
        })

      {%{"type" => "ack", "seq" => seq}, _alice} = Client.recv(alice)

      {in_tab, _tab} = Client.recv(tab)
      assert %{"type" => "text", "seq" => ^seq, "from" => "user", "clientId" => "c-9"} = in_tab

      {at_agent, _agent} = Client.recv(agent)
      assert %{"seq" => ^seq, "from" => "bot", "sender" => %{"id" => "alice"}} = at_agent
      refute Map.has_key?(at_agent, "clientId")
    end

    test "a mekik/1 id is used as the clientId", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      client = Client.push(client, %{"type" => "text", "id" => "m-1", "data" => %{"text" => "x"}})
      assert {%{"type" => "ack", "clientId" => "m-1"}, _client} = Client.recv(client)
    end

    test "a send without any id is persisted without an ack", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      client = Client.push(client, %{"type" => "text", "data" => %{"text" => "x"}})
      Client.refute_frame(client)
      assert [%Activity{text: "x"}] = Repo.all(Activity)
    end

    test "validation errors draw invalid_message with details", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      long = String.duplicate("a", 70_000)

      client =
        Client.push(client, %{"type" => "text", "clientId" => "c-2", "data" => %{"text" => long}})

      assert {%{
                "data" => %{
                  "code" => "invalid_message",
                  "clientId" => "c-2",
                  "details" => details
                }
              }, _client} = Client.recv(client)

      assert Map.has_key?(details, "text")
    end

    test "a closed conversation draws conversation_closed", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      {:ok, _} = Conversations.close_conversation(ctx.conversation)
      {%{"type" => "conversationUpdate"}, client} = Client.recv(client)

      client =
        Client.push(client, %{"type" => "text", "clientId" => "c-3", "data" => %{"text" => "x"}})

      assert {%{"data" => %{"code" => "conversation_closed", "clientId" => "c-3"}}, _client} =
               Client.recv(client)
    end

    test "malformed frames draw bad_request and keep the connection", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))

      client = Client.push(client, {:text, "not json"})
      assert {%{"data" => %{"code" => "bad_request"}}, client} = Client.recv(client)

      client = Client.push(client, %{"type" => "text", "data" => %{}})
      assert {%{"data" => %{"code" => "bad_request"}}, client} = Client.recv(client)

      client = Client.push(client, %{"type" => "welcome"})
      assert {%{"data" => %{"code" => "bad_request"}}, client} = Client.recv(client)

      client = Client.push(client, {:binary, <<1, 2, 3>>})
      assert {%{"data" => %{"code" => "bad_request"}}, client} = Client.recv(client)

      client = Client.push(client, %{"type" => "ping"})
      assert {%{"type" => "heartbeat"}, _client} = Client.recv(client)
    end

    test "bot frames draw bot_unavailable; rich types wait for #28", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))

      client = Client.push(client, %{"type" => "resume", "data" => %{}})
      assert {%{"data" => %{"code" => "bot_unavailable"}}, client} = Client.recv(client)

      client =
        Client.push(client, %{"type" => "image", "data" => %{"src" => "https://x.test/a.png"}})

      assert {%{"data" => %{"code" => "invalid_message"}}, _client} = Client.recv(client)
    end

    test "frames above maxFrameBytes draw payload_too_large", ctx do
      Application.put_env(:converger, ConvergerWeb.Protocol, max_frame_bytes: 1_000)
      on_exit(fn -> Application.delete_env(:converger, ConvergerWeb.Protocol) end)

      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      big = String.duplicate("a", 2_000)
      client = Client.push(client, %{"type" => "text", "data" => %{"text" => big}})
      assert {%{"data" => %{"code" => "payload_too_large"}}, _client} = Client.recv(client)
    end
  end

  describe "live delivery" do
    test "persistent frames are pushed live in order", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      activity!(ctx.conversation, "live")

      assert {%{"type" => "text", "seq" => 1, "data" => %{"text" => "live"}}, _} =
               Client.recv(client)
    end

    test "lifecycle activities arrive as conversationUpdate from system", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      {:ok, _} = Conversations.close_conversation(ctx.conversation)

      assert {%{
                "type" => "conversationUpdate",
                "sender" => %{"role" => "system"},
                "data" => data
              }, _client} = Client.recv(client)

      assert data["event"] == "conversation_closed"
    end

    test "sync replays after the given watermark", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      activity!(ctx.conversation, "one")
      activity!(ctx.conversation, "two")
      {_, client} = Client.recv(client)
      {_, client} = Client.recv(client)

      client = Client.push(client, %{"type" => "sync", "watermark" => 1})
      assert {%{"seq" => 2}, client} = Client.recv(client)
      Client.refute_frame(client)
    end

    test "a forced disconnect closes with 4403", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation, user_id: "alice"))
      ConvergerWeb.Sockets.disconnect_user(ctx.tenant.id, "alice")
      assert {{:close, 4403}, _client} = Client.recv(client)
    end

    test "deactivating the channel sends channel_inactive and closes with 4403", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      {:ok, channel} = Channels.update_channel(ctx.channel, %{status: "inactive"})
      ConvergerWeb.Sockets.disconnect_channel(channel.id)

      assert {%{"data" => %{"code" => "channel_inactive"}}, client} = Client.recv(client)
      assert {{:close, 4403}, _client} = Client.recv(client)
    end
  end

  describe "heartbeat, idle timeout and token lifetime" do
    test "ping is answered with heartbeat carrying the nonce", ctx do
      activity!(ctx.conversation, "one")
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      {_, client} = Client.recv(client)

      client = Client.push(client, %{"type" => "ping", "nonce" => "p-1"})
      assert {%{"type" => "heartbeat", "nonce" => "p-1", "headSeq" => 1}, _} = Client.recv(client)
    end

    test "the server sends heartbeats on outbound silence and closes idle sockets with 4408",
         ctx do
      # The schema's minimum for both is 1 s.
      Application.put_env(:converger, ConvergerWeb.Protocol,
        heartbeat_interval_ms: 1_000,
        idle_timeout_ms: 1_500
      )

      on_exit(fn -> Application.delete_env(:converger, ConvergerWeb.Protocol) end)

      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation))
      assert {%{"type" => "heartbeat"}, client} = Client.recv(client, 1_500)
      assert {{:close, 4408}, _client} = recv_close(client)
    end

    test "an expired token closes with token_expired and 4401", ctx do
      token = token(ctx.channel, ctx.conversation, expires_in: 1)
      {_welcome, client} = join(ctx.port, token)

      assert {%{"data" => %{"code" => "token_expired", "retryable" => true}}, client} =
               Client.recv_type(client, "error", 2_500)

      assert {{:close, 4401}, _client} = Client.recv(client)
    end

    test "auth refreshes the token of the session", ctx do
      {_welcome, client} = join(ctx.port, token(ctx.channel, ctx.conversation, user_id: "alice"))

      fresh = token(ctx.channel, ctx.conversation, user_id: "alice")
      client = Client.push(client, %{"type" => "auth", "token" => fresh})

      assert {%{"type" => "tokenRefreshed", "data" => %{"expiresAt" => _}}, client} =
               Client.recv_type(client, "tokenRefreshed")

      other = token(ctx.channel, ctx.conversation, user_id: "mallory")
      client = Client.push(client, %{"type" => "auth", "token" => other})
      assert {%{"data" => %{"code" => "forbidden"}}, _client} = Client.recv_type(client, "error")
    end

    defp recv_close(client) do
      case Client.recv(client, 1_000) do
        {%{"type" => "heartbeat"}, client} -> recv_close(client)
        other -> other
      end
    end
  end

  describe "MessagePack" do
    test "frames are binary MessagePack in both directions", ctx do
      token = token(ctx.channel, ctx.conversation)

      {welcome, client} =
        join(ctx.port, token, %{},
          subprotocols: ["converger.v1+msgpack"],
          encoding: :msgpack,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert Client.subprotocol(client) == "converger.v1+msgpack"
      assert welcome["data"]["protocol"] == "converger/1"

      client =
        Client.push(client, %{"type" => "text", "clientId" => "mp-1", "data" => %{"text" => "hi"}})

      assert {%{"type" => "ack", "clientId" => "mp-1", "seq" => 1}, _client} = Client.recv(client)
    end
  end
end
