defmodule Converger.Channels.KafkaIntegrationTest do
  @moduledoc """
  The `kafka` channel end to end against a real Kafka broker (issue #42).
  Excluded by default; see docs/channels/brokers.md#running-the-broker-tests:

      docker run -d --name kafka -p 9092:9092 apache/kafka:3.9.1
      KAFKA_BROKERS=localhost:9092 mix test --only kafka

  `:brod` needs its CRC32C NIF (`crc32cer`), which is not built on Windows:
  run this suite on Linux or macOS, or in a container.
  """

  use ConvergerWeb.ChannelCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  require Record

  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias Converger.{Channels, Repo, RoutingRules}
  alias Converger.Channels.Broker.Publishers
  alias Converger.Channels.Consumers
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  import Ecto.Query

  @moduletag :kafka
  @moduletag timeout: 300_000

  Record.defrecordp(
    :kafka_message,
    Record.extract(:kafka_message, from_lib: "brod/include/brod.hrl")
  )

  @partitions 3

  setup do
    brokers = System.get_env("KAFKA_BROKERS", "localhost:9092")
    {:ok, hosts} = Converger.Channels.Adapters.Kafka.hosts(%{"brokers" => brokers})

    # Brokers on localhost / a private network must pass the SSRF guard.
    webhook = Application.get_env(:converger, :webhook, [])

    Application.put_env(
      :converger,
      :webhook,
      Keyword.put(webhook, :allow_private_targets, true)
    )

    on_exit(fn -> Application.put_env(:converger, :webhook, webhook) end)

    suffix = System.unique_integer([:positive])
    topic_in = "it#{suffix}.in"
    topic_out = "it#{suffix}.out"
    dlq = "#{topic_in}.dlq"

    :ok =
      :brod.create_topics(
        hosts,
        for(
          topic <- [topic_in, topic_out, dlq],
          do: %{
            name: topic,
            num_partitions: @partitions,
            replication_factor: 1,
            assignments: [],
            configs: []
          }
        ),
        %{timeout: 15_000}
      )

    # The "external script": a client of its own.
    client = :"it_kafka_#{suffix}"
    :ok = :brod.start_client(hosts, client, auto_start_producers: true)
    on_exit(fn -> :brod.stop_client(client) end)

    tenant = tenant_fixture()

    {:ok, kafka} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "kafka",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "brokers" => brokers,
          "topic_in" => topic_in,
          "topic_out" => topic_out,
          "start_offset" => "earliest"
        }
      })

    console = channel_fixture(tenant, %{mode: "duplex"})

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "kafka to console",
        tenant_id: tenant.id,
        source_channel_id: kafka.id,
        target_channel_ids: [console.id]
      })

    on_exit(fn ->
      Consumers.stop_consumer(kafka.id)
      Publishers.stop(kafka.id)
    end)

    %{
      hosts: hosts,
      client: client,
      kafka: kafka,
      console: console,
      topic_in: topic_in,
      topic_out: topic_out,
      dlq: dlq
    }
  end

  defp produce(client, topic, key, value, headers \\ []) do
    message = %{ts: System.system_time(:millisecond), value: value, headers: headers}
    {:ok, _offset} = :brod.produce_sync_offset(client, topic, :hash, key, message)
  end

  defp fetch_all(hosts, topic) do
    for partition <- 0..(@partitions - 1),
        # A topic created a moment ago can answer not_leader_for_partition; skip it so `eventually` retries.
        {:ok, {_hw, messages}} <- [:brod.fetch(hosts, topic, partition, 0)],
        message <- messages do
      %{
        partition: partition,
        key: kafka_message(message, :key),
        value: kafka_message(message, :value),
        headers: kafka_message(message, :headers)
      }
    end
  end

  defp eventually(fun, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false, []] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met in time")
        else
          Process.sleep(200)
          do_eventually(fun, deadline)
        end

      result ->
        result
    end
  end

  defp inbound_activities(topic_in) do
    Repo.all(
      from(a in Activity,
        where: like(a.idempotency_key, ^"kafka:#{topic_in}/%"),
        order_by: [asc: a.inserted_at]
      )
    )
  end

  defp join_console(console) do
    {:ok, token, _} = ConvergerToken.generate_token(console, scope: "channel", user_id: "agent-7")
    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:channel:#{console.id}")

    socket
  end

  test "a message produced to topic_in reaches a WS client and the reply lands on topic_out", %{
    hosts: hosts,
    client: client,
    kafka: kafka,
    console: console,
    topic_in: topic_in,
    topic_out: topic_out
  } do
    socket = join_console(console)
    {:ok, _} = Consumers.start_consumer(kafka)

    produce(
      client,
      topic_in,
      "cust-1",
      Jason.encode!(%{
        "text" => "Where is my order?",
        "participant" => %{"external_id" => "cust-1", "display_name" => "Ada"}
      })
    )

    assert_push "activitySet", %{conversation_id: conversation_id, activities: [frame]}, 60_000
    assert frame.text == "Where is my order?"
    assert frame.from.id == "cust-1"

    ref =
      push(socket, "postActivity", %{
        "conversation_id" => conversation_id,
        "text" => "It ships today",
        "clientId" => "reply-1"
      })

    assert_reply ref, :ok, %{id: reply_id}, 30_000

    # Only the reply is produced: the consumed message is not echoed back.
    [message] = eventually(fn -> fetch_all(hosts, topic_out) end, 30_000)
    Process.sleep(1_000)
    assert [^message] = fetch_all(hosts, topic_out)

    assert message.key == conversation_id
    assert message.partition == :erlang.phash2(conversation_id, @partitions)

    envelope = Jason.decode!(message.value)
    assert envelope["id"] == reply_id
    assert envelope["text"] == "It ships today"
    assert envelope["sender"] == "agent-7"
    assert envelope["conversation_id"] == conversation_id
    assert envelope["tenant_id"] == kafka.tenant_id
    assert envelope["channel_id"] == kafka.id
    assert envelope["event"] == "activity.created"

    headers = Map.new(message.headers)
    assert headers["x-converger-activity-id"] == reply_id
    assert headers["x-converger-conversation-id"] == conversation_id
    assert headers["content-type"] == "application/json"

    # The delivery records topic/partition/offset as the provider message id.
    delivery = Converger.Deliveries.get_delivery_for_activity_and_channel(reply_id, kafka.id)
    assert delivery.status == "sent"
    assert delivery.provider_message_id == "#{topic_out}/#{message.partition}/0"
  end

  test "a restarted consumer resumes from committed offsets without duplicates", %{
    client: client,
    kafka: kafka,
    topic_in: topic_in
  } do
    handler = "it-kafka-#{kafka.id}"
    test = self()

    :telemetry.attach(
      handler,
      [:converger, :inbound, :received],
      fn _event, _measurements, %{channel_id: id, outcome: outcome}, _ ->
        if id == kafka.id, do: send(test, {:inbound, outcome})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, _} = Consumers.start_consumer(kafka)
    produce(client, topic_in, "a", ~s({"text": "one"}))
    assert_receive {:inbound, :created}, 60_000

    # Stopping drains the pipeline and commits the offset.
    :ok = Consumers.stop_consumer(kafka.id)
    produce(client, topic_in, "b", ~s({"text": "two"}))
    produce(client, topic_in, "c", ~s({"text": "three"}))

    {:ok, _} = Consumers.start_consumer(kafka)
    assert_receive {:inbound, :created}, 60_000
    assert_receive {:inbound, :created}, 60_000
    refute_receive {:inbound, _}, 3_000

    assert inbound_activities(topic_in) |> Enum.map(& &1.text) |> Enum.sort() ==
             ~w(one three two)

    # Offsets lost (a new consumer group reads the topic from the start):
    # every message is redelivered and recognised by its broker message id.
    :ok = Consumers.stop_consumer(kafka.id)

    {:ok, kafka} =
      Channels.update_channel(kafka, %{
        config: Map.put(kafka.config, "group_id", "it-fresh-#{kafka.id}")
      })

    {:ok, _} = Consumers.start_consumer(kafka)

    for _ <- 1..3, do: assert_receive({:inbound, :duplicate}, 60_000)
    refute_receive {:inbound, :created}, 2_000
    assert length(inbound_activities(topic_in)) == 3
  end

  test "poison messages are produced to the dead-letter topic", %{
    hosts: hosts,
    client: client,
    kafka: kafka,
    topic_in: topic_in,
    dlq: dlq
  } do
    {:ok, _} = Consumers.start_consumer(kafka)

    produce(client, topic_in, "k1", "{not json", [{"trace-id", "t-1"}])

    produce(
      client,
      topic_in,
      "k2",
      Jason.encode!(%{"text" => "x", "tenant_id" => Ecto.UUID.generate()})
    )

    produce(client, topic_in, "k3", ~s({"text": "fine"}))

    dead = eventually(fn -> if length(fetch_all(hosts, dlq)) == 2, do: fetch_all(hosts, dlq) end)

    by_key = Map.new(dead, &{&1.key, &1})

    assert by_key["k1"].value == "{not json"
    headers = Map.new(by_key["k1"].headers)
    assert headers["x-converger-error"] == "message body is not valid JSON"
    assert headers["x-converger-channel-id"] == kafka.id
    assert headers["trace-id"] == "t-1"
    assert headers["x-converger-source"] =~ ~r"^#{Regex.escape(topic_in)}/\d/\d+$"

    assert Map.new(by_key["k2"].headers)["x-converger-error"] ==
             "tenant_id does not match the consuming channel"

    # The good message after them is accepted.
    eventually(fn -> inbound_activities(topic_in) end)
    assert [%{text: "fine"}] = inbound_activities(topic_in)
  end
end
