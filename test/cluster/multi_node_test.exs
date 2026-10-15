defmodule Converger.MultiNodeTest do
  @moduledoc """
  Two-node cluster suite (issue #29). Boots two Converger nodes with OTP's
  `:peer`, clustered by libcluster over Erlang distribution and sharing one
  Postgres database, and checks what a load-balanced deployment relies on:

    * an activity created on node A reaches a WebSocket client on node B
      (Phoenix.PubSub across nodes);
    * rate limits are shared (the `:cluster` backend, ADR-0013);
    * a client token revoked on one node is rejected by the other within a
      second (ADR-0059);
    * every delivery job is executed exactly once although both nodes run
      the Oban queues;
    * an agent group (`hello.group`, ADR-0069) with a member on each node
      delivers each user turn to one member, and the member on the other
      node takes over when one leaves.

  Excluded by default (it starts extra VMs). Run it with

      mix test --only cluster

  See docs/operations/clustering.md and test/support/cluster/peer.ex.
  """

  use ExUnit.Case, async: false

  alias Converger.{ActivitiesFixtures, ChannelsFixtures, ConversationsFixtures, TenantsFixtures}
  alias Converger.TestCluster.{Peer, WebhookSink, WsClient}
  alias ConvergerWeb.ProtocolClient

  @moduletag :cluster
  @moduletag timeout: 300_000

  setup_all do
    {name_a, node_a} = Peer.node_name("converger_a")
    {name_b, node_b} = Peer.node_name("converger_b")
    hosts = [node_a, node_b]
    [port_a, port_b] = [free_port(), free_port()]

    {a, ^node_a} = Peer.start(name_a, port: port_a, hosts: hosts)
    :ok = Peer.prepare_database(a)
    :ok = Peer.start_app(a)
    :ok = Peer.truncate_all(a)

    {b, ^node_b} = Peer.start(name_b, port: port_b, hosts: hosts)
    :ok = Peer.start_app(b)

    on_exit(fn ->
      for pid <- [b, a] do
        try do
          :peer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    # libcluster (Epmd strategy) connects the nodes.
    Peer.eventually(fn ->
      node_a in Peer.call(b, Node, :list, []) and node_b in Peer.call(a, Node, :list, [])
    end)

    %{a: %{pid: a, node: node_a, port: port_a}, b: %{pid: b, node: node_b, port: port_b}}
  end

  test "the nodes are clustered and both report ready", %{a: a, b: b} do
    for %{port: port} <- [a, b] do
      assert %{status: 200, body: %{"status" => "ready"}} = http(:get, port, "/health/ready")
    end
  end

  test "an activity created on node A reaches a WebSocket client connected to node B", %{
    a: a,
    b: b
  } do
    tenant = Peer.call(a.pid, TenantsFixtures, :tenant_fixture, [%{}])
    channel = Peer.call(a.pid, ChannelsFixtures, :channel_fixture, [tenant])

    conversation =
      Peer.call(a.pid, ConversationsFixtures, :conversation_fixture, [tenant, channel])

    # Converger API socket (the client protocol, ADR-0026).
    {:ok, token, _claims} =
      Peer.call(a.pid, Converger.Auth.ConvergerToken, :generate_conversation_token, [
        channel,
        conversation.id,
        [user_id: "ws-user"]
      ])

    topic = "converger:conversation:#{conversation.id}"

    {:ok, client} =
      WsClient.connect(b.port, "/socket/converger/websocket?token=#{token}&vsn=2.0.0")

    {:ok, _response, client} = WsClient.join(client, topic)

    # Created through node A's tenant REST API; broadcast on node A.
    assert %{status: 201} =
             http(:post, a.port, "/api/v1/conversations/#{conversation.id}/activities",
               json: %{text: "hello from node A", type: "message"},
               headers: [{"x-api-key", tenant.api_key}]
             )

    assert {:ok,
            [_, _, ^topic, "activitySet", %{"activities" => [%{"text" => "hello from node A"}]}],
            client} =
             WsClient.await(client, &match?([_, _, ^topic, "activitySet", _], &1), 10_000)

    WsClient.close(client)
  end

  test "rate limits are shared between the nodes", %{a: a, b: b} do
    # token_create (the deprecated POST /api/v1/tokens, the only bucket keyed by
    # client IP alone): 10 per minute by default. Stay away from
    # the end of a window so the hits on A and B land in the same one.
    {limit, scale_ms} = Peer.call(a.pid, Converger.RateLimit, :limit_for, [:token_create])
    wait_for_window_start(scale_ms, 10_000)

    for _ <- 1..limit do
      assert %{status: status} = http(:post, a.port, "/api/v1/tokens", json: token_params())
      assert status != 429
    end

    # Node B learns about node A's hits through the PubSub sync ...
    Peer.eventually(fn ->
      match?(
        {:deny, _, _},
        Peer.call(b.pid, Converger.RateLimit, :peek, [:token_create, "ip:127.0.0.1"])
      )
    end)

    # ... and rejects the client although it never saw it before.
    assert %{status: 429} = http(:post, b.port, "/api/v1/tokens", json: token_params())
  end

  test "a token revoked on node A is rejected by node B within a second", %{a: a, b: b} do
    tenant = Peer.call(a.pid, TenantsFixtures, :tenant_fixture, [%{}])
    channel = Peer.call(a.pid, ChannelsFixtures, :channel_fixture, [tenant])
    secret = [{"authorization", "Bearer #{channel.secret}"}]

    %{status: 200, body: %{"token" => token}} =
      http(:post, a.port, "/api/v1/converger/tokens/generate",
        json: %{user: %{id: "revoked-user"}},
        headers: secret
      )

    bearer = [{"authorization", "Bearer #{token}"}]

    # Node B knows the token (and its cache is warm).
    assert %{status: 201} =
             http(:post, b.port, "/api/v1/converger/conversations", headers: bearer)

    {:ok, client} =
      WsClient.connect(b.port, "/socket/converger/websocket?token=#{token}&vsn=2.0.0")

    assert %{status: 200, body: %{"revoked" => "token"}} =
             http(:post, a.port, "/api/v1/converger/tokens/revoke", headers: bearer)

    revoked_at = System.monotonic_time(:millisecond)

    Peer.eventually(fn ->
      match?(
        %{status: 401, body: %{"error" => %{"code" => "token_revoked"}}},
        http(:post, b.port, "/api/v1/converger/conversations", headers: bearer)
      )
    end)

    assert System.monotonic_time(:millisecond) - revoked_at < 1_000

    # The socket on node B was disconnected and cannot reconnect.
    assert {:error, :closed} = WsClient.await(client, fn _ -> false end, 2_000)

    assert {:error, _} =
             WsClient.connect(b.port, "/socket/converger/websocket?token=#{token}&vsn=2.0.0")
  end

  test "each delivery job is executed exactly once with both nodes running Oban", %{a: a, b: b} do
    sink =
      start_supervised!(
        {Bandit, plug: {WebhookSink, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, sink_port}} = ThousandIsland.listener_info(sink)

    tenant = Peer.call(a.pid, TenantsFixtures, :tenant_fixture, [%{}])

    channel =
      Peer.call(a.pid, ChannelsFixtures, :webhook_channel_fixture, [
        tenant,
        %{mode: "outbound", config: %{"url" => "http://127.0.0.1:#{sink_port}/hook"}}
      ])

    conversation =
      Peer.call(a.pid, ConversationsFixtures, :conversation_fixture, [tenant, channel])

    count = 20

    # Activities are created on both nodes; both nodes poll the deliveries queue.
    activity_ids =
      for i <- 1..count do
        node = if rem(i, 2) == 0, do: a, else: b

        Peer.call(node.pid, ActivitiesFixtures, :activity_fixture, [
          tenant,
          conversation,
          %{text: "delivery #{i}", sender: "agent"}
        ]).id
      end

    delivered =
      for _ <- 1..count do
        assert_receive {:webhook, %{"id" => id}, _headers}, 30_000
        id
      end

    # No duplicates arrive later.
    refute_receive {:webhook, _, _}, 2_000

    assert Enum.sort(delivered) == Enum.sort(activity_ids)

    # Only this test's webhook channel: other tests' activities (the websocket
    # channel is a delivery target too) have delivery jobs of their own.
    %{rows: jobs} =
      Peer.call(a.pid, Converger.Repo, :query!, [
        "SELECT state, attempt, attempted_by[1] FROM oban_jobs WHERE worker = $1 AND args->>'channel_id' = $2",
        ["Converger.Workers.ActivityDeliveryWorker", channel.id]
      ])

    assert length(jobs) == count

    assert Enum.all?(jobs, fn [state, attempt, _node] -> state == "completed" and attempt == 1 end)

    executing_nodes = jobs |> Enum.map(fn [_, _, node] -> node end) |> Enum.uniq()
    assert Enum.all?(executing_nodes, &(&1 in [to_string(a.node), to_string(b.node)]))
  end

  test "an agent group spans the nodes: one member per turn, takeover when a node's member leaves",
       %{a: a, b: b} do
    tenant = Peer.call(a.pid, TenantsFixtures, :tenant_fixture, [%{}])
    widget = Peer.call(a.pid, ChannelsFixtures, :channel_fixture, [tenant])
    bot = Peer.call(a.pid, ChannelsFixtures, :channel_fixture, [tenant])

    {:ok, _rule} =
      Peer.call(a.pid, Converger.RoutingRules, :create_routing_rule, [
        %{
          name: "widget to bot",
          tenant_id: tenant.id,
          source_channel_id: widget.id,
          target_channel_ids: [bot.id]
        }
      ])

    conversations =
      for _ <- 1..12,
          do: Peer.call(a.pid, ConversationsFixtures, :conversation_fixture, [tenant, widget])

    # One agent process on each node, in the same group.
    agent_a = group_agent(a, bot, "agent-a")
    agent_b = group_agent(b, bot, "agent-b")
    # Longer than the settle delay and the :pg propagation between the nodes.
    Process.sleep(1_000)

    # Turns are committed on both nodes.
    for {conversation, i} <- Enum.with_index(conversations) do
      user_turn(if(rem(i, 2) == 0, do: a, else: b), widget, conversation, "first")
    end

    {turns_a, agent_a} = drain_turns(agent_a)
    {turns_b, agent_b} = drain_turns(agent_b)

    assert Enum.sort(turns_a ++ turns_b) ==
             Enum.sort(for c <- conversations, do: {c.id, "first"})

    served_a = turns_a |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    assert MapSet.size(served_a) in 1..11

    # The member on node A leaves without answering: the member on node B
    # takes its conversations over (their unanswered turns, once) and gets
    # every later turn, once.
    ProtocolClient.close(agent_a)
    {taken_over, agent_b} = drain_turns(agent_b)
    assert Enum.sort(taken_over) == Enum.sort(for id <- served_a, do: {id, "first"})

    for conversation <- conversations, do: user_turn(a, widget, conversation, "second")
    {turns, agent_b} = drain_turns(agent_b)
    assert Enum.sort(turns) == Enum.sort(for c <- conversations, do: {c.id, "second"})

    ProtocolClient.close(agent_b)
  end

  defp group_agent(node, bot, name) do
    {:ok, token, _claims} =
      Peer.call(node.pid, Converger.Auth.ConvergerToken, :generate_token, [
        bot,
        [scope: "channel", user_id: name]
      ])

    {:ok, client} =
      ProtocolClient.connect(node.port, headers: [{"authorization", "Bearer #{token}"}])

    client = ProtocolClient.push(client, %{"type" => "hello", "group" => "workers"})
    assert {%{"type" => "welcome"}, client} = ProtocolClient.recv(client, 5_000)
    client
  end

  defp user_turn(node, widget, conversation, text) do
    message = %{"type" => "message", "sender" => "alice", "text" => text}

    assert {:created, _activity} =
             Peer.call(node.pid, Converger.Inbound, :receive_message, [
               widget,
               message,
               [conversation_id: conversation.id]
             ])
  end

  # The user turns an agent receives until it is quiet for 2 s (deliveries go
  # through the Oban queues of both nodes).
  defp drain_turns(client, acc \\ []) do
    case ProtocolClient.recv(client, 2_000) do
      {:timeout, client} ->
        {Enum.reverse(acc), client}

      {%{"conversationId" => id, "frame" => %{"type" => "text", "from" => "user"} = frame},
       client} ->
        drain_turns(client, [{id, frame["data"]["text"]} | acc])

      {%{}, client} ->
        drain_turns(client, acc)

      {other, _client} ->
        flunk("unexpected #{inspect(other)}")
    end
  end

  defp http(method, port, path, opts \\ []) do
    resp =
      Req.request!([method: method, url: "http://127.0.0.1:#{port}#{path}", retry: false] ++ opts)

    %{status: resp.status, body: resp.body}
  end

  # Well-formed but unknown: answered with 404 after the rate limit plug.
  # (A malformed body raises in the controller and makes the server close
  # the keep-alive connection, which a pooled client may then reuse.)
  defp token_params, do: %{conversation_id: Ecto.UUID.generate(), user_id: "rate-limit-test"}

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp wait_for_window_start(scale_ms, margin_ms) do
    into_window = rem(System.system_time(:millisecond), scale_ms)
    if into_window > scale_ms - margin_ms, do: Process.sleep(scale_ms - into_window + 50)
  end
end
