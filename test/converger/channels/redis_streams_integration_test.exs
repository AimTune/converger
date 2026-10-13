defmodule Converger.Channels.RedisStreamsIntegrationTest do
  @moduledoc """
  The `redis_streams` channel end to end against a real Redis server (issue
  #42). Excluded by default; see
  docs/channels/brokers.md#running-the-broker-tests:

      docker run -d --name redis -p 6379:6379 redis:7
      REDIS_URL=redis://localhost:6379 mix test --only redis_streams
  """

  use ConvergerWeb.ChannelCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Ecto.Query

  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias Converger.{Channels, Repo, RoutingRules}
  alias Converger.Channels.Adapters.RedisStreams
  alias Converger.Channels.Broker.Publishers
  alias Converger.Channels.Consumers
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  @moduletag :redis_streams
  @moduletag timeout: 300_000

  setup do
    url = System.get_env("REDIS_URL", "redis://localhost:6379")

    webhook = Application.get_env(:converger, :webhook, [])
    Application.put_env(:converger, :webhook, Keyword.put(webhook, :allow_private_targets, true))
    on_exit(fn -> Application.put_env(:converger, :webhook, webhook) end)

    suffix = System.unique_integer([:positive])
    stream_in = "it#{suffix}.in"
    stream_out = "it#{suffix}.out"

    # The "external script": a connection of its own.
    {:ok, redis} = RedisStreams.connect(%{"url" => url})

    on_exit(fn ->
      {:ok, redis} = RedisStreams.connect(%{"url" => url})
      Redix.command(redis, ["DEL", stream_in, stream_out, "#{stream_in}.dlq"])
      Redix.stop(redis)
    end)

    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "redis_streams",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "url" => url,
          "stream_in" => stream_in,
          "stream_out" => stream_out,
          "maxlen" => 1_000
        }
      })

    console = channel_fixture(tenant, %{mode: "duplex"})

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "redis to console",
        tenant_id: tenant.id,
        source_channel_id: channel.id,
        target_channel_ids: [console.id]
      })

    on_exit(fn ->
      Consumers.stop_consumer(channel.id)
      Publishers.stop(channel.id)
    end)

    %{
      redis: redis,
      channel: channel,
      console: console,
      group: RedisStreams.group(channel),
      stream_in: stream_in,
      stream_out: stream_out
    }
  end

  defp xadd(redis, stream, fields) do
    {:ok, id} = Redix.command(redis, ["XADD", stream, "*" | fields])
    id
  end

  defp entries(redis, stream) do
    {:ok, entries} = Redix.command(redis, ["XRANGE", stream, "-", "+"])

    for [id, fields] <- entries do
      {id, fields |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)}
    end
  end

  defp group_ready?(redis, stream, group) do
    case Redix.command(redis, ["XINFO", "GROUPS", stream]) do
      {:ok, groups} -> Enum.any?(groups, &(group in &1))
      {:error, _} -> false
    end
  end

  defp pending_count(redis, stream, group) do
    {:ok, [count | _]} = Redix.command(redis, ["XPENDING", stream, group])
    count
  end

  defp eventually(fun, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false, []] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met in time")
        else
          Process.sleep(100)
          do_eventually(fun, deadline)
        end

      result ->
        result
    end
  end

  defp inbound_activities(channel_id) do
    Repo.all(
      from(a in Activity,
        join: c in Converger.Conversations.Conversation,
        on: c.id == a.conversation_id,
        where: c.channel_id == ^channel_id,
        order_by: [asc: a.inserted_at]
      )
    )
  end

  defp attach_inbound(channel_id) do
    handler = "it-redis-#{channel_id}"
    test = self()

    :telemetry.attach(
      handler,
      [:converger, :inbound, :received],
      fn _event, _measurements, %{channel_id: id, outcome: outcome}, _ ->
        if id == channel_id, do: send(test, {:inbound, outcome})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "an entry added to stream_in reaches a WS client and the reply is appended", %{
    redis: redis,
    channel: channel,
    console: console,
    group: group,
    stream_in: stream_in,
    stream_out: stream_out
  } do
    {:ok, token, _} = ConvergerToken.generate_token(console, scope: "channel", user_id: "agent-7")
    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:channel:#{console.id}")

    {:ok, _} = Consumers.start_consumer(channel)
    eventually(fn -> group_ready?(redis, stream_in, group) end)

    xadd(redis, stream_in, [
      "payload",
      Jason.encode!(%{"text" => "Hello", "participant" => %{"external_id" => "cust-1"}})
    ])

    assert_push "activitySet", %{conversation_id: conversation_id, activities: [frame]}, 30_000
    assert frame.text == "Hello"

    ref =
      push(socket, "postActivity", %{"conversation_id" => conversation_id, "text" => "Hi there"})

    assert_reply ref, :ok, %{id: reply_id}, 30_000

    [{_id, fields}] = eventually(fn -> entries(redis, stream_out) end)
    # Only the reply: the consumed entry is not echoed back.
    Process.sleep(500)
    assert length(entries(redis, stream_out)) == 1

    envelope = Jason.decode!(fields["payload"])
    assert envelope["id"] == reply_id
    assert envelope["text"] == "Hi there"
    assert envelope["conversation_id"] == conversation_id
    assert envelope["channel_id"] == channel.id
    assert envelope["tenant_id"] == channel.tenant_id

    assert fields["activity_id"] == reply_id
    assert fields["conversation_id"] == conversation_id
    assert fields["content_type"] == "application/json"
  end

  test "a restarted consumer resumes without duplicates; a replay is recognised", %{
    redis: redis,
    channel: channel,
    group: group,
    stream_in: stream_in
  } do
    attach_inbound(channel.id)
    {:ok, _} = Consumers.start_consumer(channel)
    eventually(fn -> group_ready?(redis, stream_in, group) end)

    id1 = xadd(redis, stream_in, ["payload", ~s({"text": "one"})])
    assert_receive {:inbound, :created}, 30_000

    :ok = Consumers.stop_consumer(channel.id)
    id2 = xadd(redis, stream_in, ["payload", ~s({"text": "two"})])
    id3 = xadd(redis, stream_in, ["payload", ~s({"text": "three"})])

    {:ok, _} = Consumers.start_consumer(channel)
    assert_receive {:inbound, :created}, 30_000
    assert_receive {:inbound, :created}, 30_000
    refute_receive {:inbound, _}, 2_000

    assert channel.id |> inbound_activities() |> Enum.map(& &1.idempotency_key) |> Enum.sort() ==
             Enum.sort(for id <- [id1, id2, id3], do: "redis_streams:#{stream_in}/#{id}")

    # Everything was acknowledged.
    eventually(fn -> pending_count(redis, stream_in, group) == 0 end)

    # A replay (the group rewound to the start) brings the same entry ids
    # again: duplicates, no new activities.
    :ok = Consumers.stop_consumer(channel.id)
    {:ok, "OK"} = Redix.command(redis, ["XGROUP", "SETID", stream_in, group, "0"])
    {:ok, _} = Consumers.start_consumer(channel)

    for _ <- 1..3, do: assert_receive({:inbound, :duplicate}, 30_000)
    assert length(inbound_activities(channel.id)) == 3
  end

  test "entries left pending by a consumer that died are recovered on start", %{
    redis: redis,
    channel: channel,
    group: group,
    stream_in: stream_in
  } do
    attach_inbound(channel.id)

    # Another node's consumer read two entries and died before acknowledging.
    {:ok, _} = Redix.command(redis, ["XGROUP", "CREATE", stream_in, group, "0", "MKSTREAM"])
    xadd(redis, stream_in, ["payload", ~s({"text": "one"})])
    xadd(redis, stream_in, ["payload", ~s({"text": "two"})])

    {:ok, [[_, [_, _]]]} =
      Redix.command(redis, [
        "XREADGROUP",
        "GROUP",
        group,
        "converger@dead-node",
        "COUNT",
        "10",
        "STREAMS",
        stream_in,
        ">"
      ])

    assert pending_count(redis, stream_in, group) == 2
    xadd(redis, stream_in, ["payload", ~s({"text": "three"})])

    {:ok, _} = Consumers.start_consumer(channel)
    for _ <- 1..3, do: assert_receive({:inbound, :created}, 30_000)
    refute_receive {:inbound, _}, 1_000

    assert channel.id |> inbound_activities() |> Enum.map(& &1.text) == ~w(one two three)
    eventually(fn -> pending_count(redis, stream_in, group) == 0 end)
  end

  test "poison entries are appended to the dead-letter stream", %{
    redis: redis,
    channel: channel,
    group: group,
    stream_in: stream_in
  } do
    {:ok, _} = Consumers.start_consumer(channel)
    eventually(fn -> group_ready?(redis, stream_in, group) end)

    bad = xadd(redis, stream_in, ["payload", "{not json", "trace-id", "t-1"])
    no_payload = xadd(redis, stream_in, ["text", "hi"])
    xadd(redis, stream_in, ["payload", ~s({"text": "fine"})])

    [{_, first}, {_, second}] =
      eventually(fn ->
        case entries(redis, "#{stream_in}.dlq") do
          [_, _] = dead -> dead
          _ -> nil
        end
      end)

    assert first["payload"] == "{not json"
    assert first["trace-id"] == "t-1"
    assert first["x-converger-error"] == "message body is not valid JSON"
    assert first["x-converger-channel-id"] == channel.id
    assert first["x-converger-source"] == "#{stream_in}/#{bad}"

    refute Map.has_key?(second, "payload")
    assert second["text"] == "hi"
    assert second["x-converger-error"] == "message has no payload"
    assert second["x-converger-source"] == "#{stream_in}/#{no_payload}"

    eventually(fn -> inbound_activities(channel.id) end)
    assert [%{text: "fine"}] = inbound_activities(channel.id)
    eventually(fn -> pending_count(redis, stream_in, group) == 0 end)
  end

  test "the health probe pings the server", %{channel: channel} do
    assert RedisStreams.health_probe(channel) == :ok

    unreachable = %{channel | config: %{channel.config | "url" => "redis://127.0.0.1:1"}}
    assert {:error, _} = RedisStreams.health_probe(unreachable)
  end
end
