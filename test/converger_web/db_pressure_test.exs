defmodule ConvergerWeb.DbPressureTest do
  @moduledoc """
  Behaviour when the database is unavailable (issue #35): queries made to
  fail by `Converger.RepoFaults` raise `DBConnection.ConnectionError`, as a
  saturated pool or a paused database does.
  """

  # Not async: faults for the WebSocket tests hit every process, and the
  # pool wait window is node-global.
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]
  require Phoenix.ChannelTest
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, RepoFaults}
  alias Converger.Auth.ConvergerToken
  alias Converger.ConvergerAPI.Watermark
  alias Converger.Repo.Pressure
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}
  alias ConvergerWeb.ProtocolClient, as: Client

  @moduletag :capture_log

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    {:ok, token, _claims} = ConvergerToken.generate_conversation_token(channel, conversation.id)

    %{tenant: tenant, channel: channel, conversation: conversation, token: token}
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

  describe "HTTP" do
    test "a request that cannot reach the database is 503 with Retry-After", ctx do
      RepoFaults.fail(["activities"])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.token}")
        |> get("/api/v1/converger/conversations/#{ctx.conversation.id}/activities")

      assert %{"details" => %{"reason" => "database_unavailable"}} =
               assert_api_error(conn, 503, "unavailable")

      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..2
    end

    test "the same request succeeds once the database is back", ctx do
      RepoFaults.fail(["activities"])
      RepoFaults.clear()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.token}")
        |> get("/api/v1/converger/conversations/#{ctx.conversation.id}/activities")

      assert json_response(conn, 200)
    end
  end

  describe "readiness" do
    setup do
      previous = Application.fetch_env!(:converger, Pressure)
      Application.put_env(:converger, Pressure, Keyword.put(previous, :degraded_queue_ms, 200))
      Pressure.flush()

      on_exit(fn ->
        Application.put_env(:converger, Pressure, previous)
        Pressure.flush()
      end)
    end

    test "is 503 degraded while the pool wait is above the threshold", %{conn: conn} do
      Pressure.record(800_000)
      Pressure.flush()

      body = conn |> get("/health/ready") |> json_response(503)

      assert body["status"] == "degraded"
      assert body["reasons"] == ["database pool saturated"]
      assert body["checks"]["pool"] == "error"
      assert body["checks"]["database"] == "ok"

      # Recovers with the next window.
      Pressure.flush()
      assert conn |> recycle() |> get("/health/ready") |> json_response(200)
    end
  end

  describe "Converger API socket (Phoenix binding)" do
    setup ctx do
      {:ok, socket} = Phoenix.ChannelTest.connect(ConvergerSocket, %{"token" => ctx.token})
      %{socket: socket}
    end

    test "a join that cannot reach the database is refused as retryable", ctx do
      RepoFaults.fail(["channels"])

      assert {:error, %{reason: "unavailable", retry_after_ms: retry_after_ms}} =
               subscribe_and_join(
                 ctx.socket,
                 ConvergerChannel,
                 "converger:conversation:#{ctx.conversation.id}"
               )

      assert retry_after_ms in 1_000..2_000
    end

    test "the join succeeds when the replay fails, with replay_unavailable", ctx do
      first = activity!(ctx.conversation, "one")
      _second = activity!(ctx.conversation, "two")
      RepoFaults.fail(["activities"])

      {:ok, _, socket} =
        subscribe_and_join(
          ctx.socket,
          ConvergerChannel,
          "converger:conversation:#{ctx.conversation.id}",
          %{"watermark" => Watermark.encode(first.seq)}
        )

      watermark = Watermark.encode(first.seq)
      assert_push "error", %{code: "replay_unavailable", watermark: ^watermark}
      refute_push "activitySet", _

      # Still joined: the next live activity arrives.
      RepoFaults.clear()
      third = activity!(ctx.conversation, "three")
      third_id = third.id
      assert_push "activitySet", %{activities: [%{id: ^third_id}]}
      assert Process.alive?(socket.channel_pid)
    end

    test "a client event that cannot reach the database is answered unavailable", ctx do
      {:ok, _, socket} =
        subscribe_and_join(
          ctx.socket,
          ConvergerChannel,
          "converger:conversation:#{ctx.conversation.id}"
        )

      RepoFaults.fail(["conversations", "activities", "channels"])

      ref = Phoenix.ChannelTest.push(socket, "read", %{"watermark" => 1})
      assert_reply ref, :error, %{reason: "unavailable", retry_after_ms: _}, 1_000
      assert Process.alive?(socket.channel_pid)
    end
  end

  describe "socket connect" do
    test "a connect that cannot reach the database is refused with 503 + Retry-After", ctx do
      RepoFaults.fail(["channels"])

      assert {:error, :database_unavailable} =
               Phoenix.ChannelTest.connect(ConvergerSocket, %{"token" => ctx.token})

      conn = ConvergerWeb.SocketGuard.handle_error(build_conn(), :database_unavailable)
      assert conn.status == 503
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..2
    end
  end

  describe "Server-Sent Events" do
    test "a replay that cannot read the database ends the stream with unavailable", ctx do
      activity!(ctx.conversation, "one")
      RepoFaults.fail(["activities"], pids: :any)

      port = Client.start_server()
      path = "/api/v1/converger/conversations/#{ctx.conversation.id}/events?watermark=0"

      {200, client} =
        Client.sse_connect(port, path, [{"authorization", "Bearer #{ctx.token}"}])

      assert {%{frame: %{"type" => "error", "data" => %{"code" => "unavailable"} = data}}, client} =
               Client.sse_recv(client)

      assert data["retryable"]
      assert is_integer(data["retryAfterMs"])
      # The stream ends; EventSource reconnects with Last-Event-ID.
      assert {:done, _client} = Client.sse_recv(client)
    end
  end

  describe "native v1 WebSocket" do
    setup do
      %{port: Client.start_server()}
    end

    defp connect_v1(port, token) do
      {:ok, client} = Client.connect(port, headers: [{"authorization", "Bearer #{token}"}])
      client
    end

    test "the session starts when the replay fails; sync recovers it", ctx do
      first = activity!(ctx.conversation, "one")
      _second = activity!(ctx.conversation, "two")
      RepoFaults.fail(["activities"], pids: :any)

      client =
        ctx.port
        |> connect_v1(ctx.token)
        |> Client.push(%{"type" => "hello", "watermark" => first.seq})

      assert {%{"type" => "welcome", "data" => %{"watermark" => 2}}, client} = Client.recv(client)

      assert {%{"type" => "error", "data" => error}, client} = Client.recv(client)

      assert %{
               "code" => "replay_unavailable",
               "retryable" => true,
               "details" => %{"watermark" => 1},
               "retryAfterMs" => _
             } = error

      RepoFaults.clear()
      client = Client.push(client, %{"type" => "sync", "watermark" => first.seq})
      assert {%{"type" => "text", "seq" => 2}, client} = Client.recv(client)
      Client.close(client)
    end

    test "a hello that cannot reach the database closes with 1013", ctx do
      RepoFaults.fail(["channels"], pids: :any)

      client = ctx.port |> connect_v1(ctx.token) |> Client.push(%{"type" => "hello"})

      assert {%{"type" => "error", "data" => %{"code" => "unavailable", "retryable" => true}},
              client} = Client.recv(client)

      assert {{:close, 1013}, _client} = Client.recv(client)
    end
  end
end
