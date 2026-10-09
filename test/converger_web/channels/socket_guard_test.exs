defmodule ConvergerWeb.SocketGuardTest do
  # Real WebSocket connections against a Bandit listener: the limits live in
  # the transport, which Phoenix.ChannelTest bypasses.
  use ConvergerWeb.ChannelCase, async: false

  import ExUnit.CaptureLog
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias ConvergerWeb.{Drain, SocketGuard, WsTestClient}

  setup do
    {_pid, port} = WsTestClient.start_server()

    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    {:ok, token, _claims} =
      Converger.Auth.Token.generate_token(conversation, tenant, "guard-user")

    original = Application.fetch_env!(:converger, :websocket)
    on_exit(fn -> Application.put_env(:converger, :websocket, original) end)
    on_exit(&Drain.reset/0)

    %{
      port: port,
      tenant: tenant,
      conversation: conversation,
      path: "/socket/websocket?vsn=2.0.0&token=#{token}"
    }
  end

  defp put_limits(limits) do
    Application.put_env(
      :converger,
      :websocket,
      Keyword.merge(Application.fetch_env!(:converger, :websocket), limits)
    )
  end

  defp connect!(%{port: port, path: path}) do
    {:ok, sock} = WsTestClient.connect(port, path)
    sock
  end

  defp heartbeat(sock, ref), do: WsTestClient.push(sock, nil, ref, "phoenix", "heartbeat", %{})

  defp reply(sock, ref) do
    WsTestClient.recv_until(sock, &match?({:message, [_, ^ref, _, "phx_reply", _]}, &1))
  end

  # Waits until every joined channel has run its after-join queries, so none
  # is killed mid-query (which breaks the shared sandbox connection).
  defp await_channels(tenant) do
    ref = make_ref()
    send(wait_for_transport(tenant), {:debug_channels, ref, self()})
    assert_receive {:debug_channels, ^ref, channels}
    Enum.each(channels, &:sys.get_state(&1.pid))
  end

  # Finds the socket (transport) process through its PubSub subscription to
  # the socket id; the subscription happens just after the upgrade.
  defp wait_for_transport(tenant, attempts \\ 50) do
    case Registry.lookup(Converger.PubSub, "user_socket:#{tenant.id}:guard-user") do
      [{pid, _}] ->
        pid

      [] when attempts > 0 ->
        Process.sleep(10)
        wait_for_transport(tenant, attempts - 1)
    end
  end

  describe "message rate" do
    test "frames above the per-socket rate get rate_limited with retryAfterMs", ctx do
      put_limits(max_messages: 3, rate_window_ms: 60_000)
      sock = connect!(ctx)

      for ref <- ~w(1 2 3) do
        heartbeat(sock, ref)

        assert {:message, [_, ^ref, "phoenix", "phx_reply", %{"status" => "ok"}]} =
                 reply(sock, ref)
      end

      heartbeat(sock, "4")

      assert {:message,
              [
                _,
                "4",
                "phoenix",
                "phx_reply",
                %{"status" => "error", "response" => %{"reason" => "rate_limited"} = response}
              ]} = reply(sock, "4")

      assert response["retryAfterMs"] in 1..60_000
    end

    test "the window resets", ctx do
      put_limits(max_messages: 1, rate_window_ms: 50)
      sock = connect!(ctx)

      heartbeat(sock, "1")
      assert {:message, [_, _, _, _, %{"status" => "ok"}]} = reply(sock, "1")
      Process.sleep(60)
      heartbeat(sock, "2")
      assert {:message, [_, _, _, _, %{"status" => "ok"}]} = reply(sock, "2")
    end
  end

  describe "frame size" do
    test "a frame above max_frame_bytes is refused with payload_too_large", ctx do
      put_limits(max_frame_bytes: 1_000)
      sock = connect!(ctx)

      WsTestClient.push(sock, nil, "1", "phoenix", "heartbeat", %{
        pad: String.duplicate("a", 2_000)
      })

      assert {:message,
              [
                _,
                "1",
                _,
                "phx_reply",
                %{"status" => "error", "response" => %{"reason" => "payload_too_large"}}
              ]} =
               reply(sock, "1")

      # The socket stays usable.
      heartbeat(sock, "2")
      assert {:message, [_, "2", _, _, %{"status" => "ok"}]} = reply(sock, "2")
    end

    test "a frame above the hard cap closes the socket with 1009 and no crash log", ctx do
      sock = connect!(ctx)
      hard_cap = Application.fetch_env!(:converger, :websocket_max_frame_size)

      log =
        capture_log([level: :warning], fn ->
          WsTestClient.send_text(sock, String.duplicate("a", hard_cap + 1))
          assert {:close, 1009, _} = WsTestClient.recv(sock)
          Process.sleep(50)
        end)

      # Bandit would log "** (exit) {:deserializing, :max_frame_size_exceeded}".
      refute log =~ "max_frame_size"
      refute log =~ "ConvergerWeb.UserSocket"
    end
  end

  describe "joins" do
    test "joins above max_joins are refused with too_many_joins",
         %{conversation: conversation} = ctx do
      put_limits(max_joins: 1)
      sock = connect!(ctx)
      topic = "conversation:#{conversation.id}"

      WsTestClient.push(sock, "1", "1", topic, "phx_join", %{})
      assert {:message, [_, "1", ^topic, "phx_reply", %{"status" => "ok"}]} = reply(sock, "1")
      await_channels(ctx.tenant)

      WsTestClient.push(sock, "2", "2", "conversation:other", "phx_join", %{})

      assert {:message,
              [
                "2",
                "2",
                "conversation:other",
                "phx_reply",
                %{"status" => "error", "response" => %{"reason" => "too_many_joins"}}
              ]} = reply(sock, "2")

      # Rejoining an already joined topic is not a new join.
      WsTestClient.push(sock, "3", "3", topic, "phx_join", %{})
      assert {:message, [_, "3", ^topic, "phx_reply", %{"status" => "ok"}]} = reply(sock, "3")
      await_channels(ctx.tenant)
    end
  end

  describe "slow consumers" do
    test "a socket whose outbound backlog exceeds the limit is closed with 4503",
         %{tenant: tenant} = ctx do
      put_limits(slow_consumer_queue_len: 5)
      sock = connect!(ctx)
      pid = wait_for_transport(tenant)

      # Pile up frames while the socket process cannot run.
      :erlang.suspend_process(pid)
      for _ <- 1..20, do: send(pid, {:socket_push, :text, ~s([null,null,"t","e",{}])})
      :erlang.resume_process(pid)

      assert {:close, 4503, reason} =
               WsTestClient.recv_until(sock, &match?({:close, _, _}, &1))

      assert %{"reason" => "slow_consumer", "retryAfterMs" => retry} = Jason.decode!(reason)
      assert retry >= 1_000
    end

    test "push_ephemeral drops frames when the client is behind" do
      put_limits(ephemeral_drop_queue_len: 2)

      backlog = spawn(fn -> Process.sleep(:infinity) end)
      :erlang.suspend_process(backlog)
      for _ <- 1..5, do: send(backlog, :queued)

      socket = %Phoenix.Socket{
        transport_pid: backlog,
        serializer: Phoenix.Socket.V2.JSONSerializer,
        topic: "conversation:x",
        join_ref: "1",
        joined: true,
        handler: ConvergerWeb.UserSocket
      }

      assert SocketGuard.push_ephemeral(socket, "typing", %{}) == :dropped
      assert SocketGuard.push_ephemeral(%{socket | transport_pid: self()}, "typing", %{}) == :ok
      assert_received {:socket_push, :text, _}
    end
  end

  describe "draining" do
    test "drained sockets close with 1012 and a jittered retryAfterMs",
         %{tenant: tenant, conversation: conversation} = ctx do
      put_limits(reconnect_base_ms: 100, reconnect_jitter_ms: 50)
      sock = connect!(ctx)
      topic = "conversation:#{conversation.id}"

      WsTestClient.push(sock, "1", "1", topic, "phx_join", %{})
      assert {:message, [_, "1", ^topic, "phx_reply", %{"status" => "ok"}]} = reply(sock, "1")
      await_channels(tenant)

      # What Phoenix's socket drainer sends every channel process on shutdown.
      ref = make_ref()
      send(wait_for_transport(tenant), {:debug_channels, ref, self()})
      assert_receive {:debug_channels, ^ref, [%{pid: channel_pid}]}
      send(channel_pid, %Phoenix.Socket.Broadcast{event: "phx_drain"})

      assert {:close, 1012, reason} = WsTestClient.recv_until(sock, &match?({:close, _, _}, &1))
      assert %{"reason" => "unavailable", "retryAfterMs" => retry} = Jason.decode!(reason)
      assert retry in 100..150
    end

    test "stopping the drain gate (application shutdown) marks the node as draining" do
      refute Drain.draining?()
      # The supervisor restarts it; on_exit resets the flag.
      :ok = GenServer.stop(Drain)
      assert Drain.draining?()
    end

    test "new sockets are refused with 503 while draining", ctx do
      Drain.start_draining()

      assert {:error, {:http, 503, headers}} = WsTestClient.connect(ctx.port, ctx.path)
      assert {"retry-after", _} = List.keyfind(headers, "retry-after", 0)

      Drain.reset()
      assert {:ok, _sock} = WsTestClient.connect(ctx.port, ctx.path)
    end

    test "existing sockets keep working while draining until they are drained",
         %{tenant: tenant} = ctx do
      sock = connect!(ctx)
      _ = wait_for_transport(tenant)
      Drain.start_draining()

      heartbeat(sock, "1")
      assert {:message, [_, "1", _, _, %{"status" => "ok"}]} = reply(sock, "1")
    end

    test "the drainer is configured from config :converger, :websocket" do
      put_limits(drain_batch_size: 7, drain_batch_interval_ms: 11, drain_shutdown_ms: 13)
      assert Drain.drainer_config() == [batch_size: 7, batch_interval: 11, shutdown: 13]
    end
  end
end
