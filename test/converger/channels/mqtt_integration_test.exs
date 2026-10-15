defmodule Converger.Channels.MqttIntegrationTest do
  @moduledoc """
  The `mqtt` channel end to end against a real MQTT broker (issue #44).
  Excluded by default; see docs/channels/mqtt.md#running-the-mqtt-tests:

      docker run -d --name mosquitto -p 1883:1883 eclipse-mosquitto:2 mosquitto -c /mosquitto-no-auth.conf
      MQTT_HOST=localhost MQTT_PORT=1883 mix test --only mqtt

  The "external device" is a `Converger.Channels.Mqtt.Connection` of its
  own (a separate MQTT client id and session).
  """

  use ConvergerWeb.ChannelCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Ecto.Query

  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias Converger.{Channels, Repo, RoutingRules}
  alias Converger.Channels.Broker.Publishers
  alias Converger.Channels.Consumers
  alias Converger.Channels.Mqtt.Connection
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  @moduletag :mqtt
  @moduletag timeout: 300_000

  setup do
    host = System.get_env("MQTT_HOST", "localhost")
    port = String.to_integer(System.get_env("MQTT_PORT", "1883"))

    webhook = Application.get_env(:converger, :webhook, [])
    Application.put_env(:converger, :webhook, Keyword.put(webhook, :allow_private_targets, true))
    on_exit(fn -> Application.put_env(:converger, :webhook, webhook) end)

    prefix = "it#{System.unique_integer([:positive])}"

    # The external device: subscribed to the channel's outbound and
    # dead-letter topics.
    {:ok, device} =
      Connection.start_link(
        host: host,
        port: port,
        client_id: "#{prefix}-device",
        subscriptions: [{"#{prefix}/out/#", 1}, {"#{prefix}/dlq/#", 1}]
      )

    tenant = tenant_fixture()

    {:ok, mqtt} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "mqtt",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "host" => host,
          "port" => port,
          "client_id" => prefix,
          "topic_in" => "#{prefix}/in/+",
          "topic_out" => "#{prefix}/out/{conversation_id}",
          "topic_dlq" => "#{prefix}/dlq/{channel_id}"
        }
      })

    console = channel_fixture(tenant, %{mode: "duplex"})

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "mqtt to console",
        tenant_id: tenant.id,
        source_channel_id: mqtt.id,
        target_channel_ids: [console.id]
      })

    on_exit(fn ->
      Consumers.stop_consumer(mqtt.id)
      Publishers.stop(mqtt.id)
    end)

    %{device: device, mqtt: mqtt, console: console, prefix: prefix}
  end

  defp publish(device, topic, payload),
    do: :ok = Connection.publish(device, topic, payload, 1)

  defp next_message(device, timeout \\ 30_000) do
    receive do
      {:mqtt_publish, ^device, packet} ->
        if packet.qos == 1, do: Connection.ack(device, packet.packet_id)
        packet
    after
      timeout -> flunk("no MQTT message within #{timeout} ms")
    end
  end

  defp inbound_activities(channel_id) do
    Repo.all(
      from(a in Activity,
        where: a.source_channel_id == ^channel_id,
        order_by: [asc: a.inserted_at]
      )
    )
  end

  defp attach_inbound(channel_id, on_created \\ fn -> :ok end) do
    handler = "it-mqtt-#{channel_id}"
    test = self()

    :telemetry.attach(
      handler,
      [:converger, :inbound, :received],
      fn _event, _measurements, %{channel_id: id, outcome: outcome}, _ ->
        if id == channel_id do
          send(test, {:inbound, outcome})
          if outcome == :created, do: on_created.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp start_consumer(channel) do
    {:ok, pid} = Consumers.start_consumer(channel)
    pid
  end

  test "a message published to topic_in reaches a WS client and the reply is published", %{
    device: device,
    mqtt: mqtt,
    console: console,
    prefix: prefix
  } do
    {:ok, token, _} = ConvergerToken.generate_token(console, scope: "channel", user_id: "agent-7")
    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:channel:#{console.id}")

    start_consumer(mqtt)

    publish(
      device,
      "#{prefix}/in/thermostat-1",
      Jason.encode!(%{
        "text" => "Temperature is 31C",
        "participant" => %{"external_id" => "thermostat-1"}
      })
    )

    assert_push "activitySet", %{conversation_id: conversation_id, activities: [frame]}, 30_000
    assert frame.text == "Temperature is 31C"

    ref =
      push(socket, "postActivity", %{"conversation_id" => conversation_id, "text" => "Cooling on"})

    assert_reply ref, :ok, %{id: reply_id}, 30_000

    packet = next_message(device)
    assert packet.topic == "#{prefix}/out/#{conversation_id}"
    assert packet.qos == 1
    envelope = Jason.decode!(packet.payload)
    assert envelope["id"] == reply_id
    assert envelope["text"] == "Cooling on"
    assert envelope["conversation_id"] == conversation_id
    assert envelope["channel_id"] == mqtt.id

    # Only the reply: the consumed message is not echoed back.
    refute_receive {:mqtt_publish, ^device, _}, 1_000
  end

  test "a restarted subscriber gets the QoS 1 messages queued meanwhile, without duplicates", %{
    device: device,
    mqtt: mqtt,
    prefix: prefix
  } do
    attach_inbound(mqtt.id)
    start_consumer(mqtt)

    publish(device, "#{prefix}/in/a", ~s({"text": "one", "idempotency_key": "dev-1"}))
    assert_receive {:inbound, :created}, 30_000

    # Stopped: the persistent session keeps queueing at the broker.
    :ok = Consumers.stop_consumer(mqtt.id)
    publish(device, "#{prefix}/in/a", ~s({"text": "two"}))
    publish(device, "#{prefix}/in/b", ~s({"text": "three"}))

    start_consumer(mqtt)
    assert_receive {:inbound, :created}, 30_000
    assert_receive {:inbound, :created}, 30_000
    refute_receive {:inbound, _}, 2_000

    # A second copy of a message (a redelivery, or a device retrying):
    # recognised by its idempotency key, derived or sent.
    publish(device, "#{prefix}/in/b", ~s({"text": "three"}))
    publish(device, "#{prefix}/in/a", ~s({"text": "one again", "idempotency_key": "dev-1"}))
    assert_receive {:inbound, :duplicate}, 30_000
    assert_receive {:inbound, :duplicate}, 30_000

    assert mqtt.id |> inbound_activities() |> Enum.map(& &1.text) == ~w(one two three)
  end

  test "a subscriber that dies before acknowledging gets the message again, as a duplicate", %{
    device: device,
    mqtt: mqtt,
    prefix: prefix
  } do
    {:ok, crash_once} = Agent.start_link(fn -> true end)

    # The subscriber is killed right after the activity is committed and
    # before its PUBACK: the broker must deliver the message again.
    attach_inbound(mqtt.id, fn ->
      if Agent.get_and_update(crash_once, &{&1, false}), do: Process.exit(self(), :kill)
    end)

    start_consumer(mqtt)
    publish(device, "#{prefix}/in/a", ~s({"text": "exactly once"}))

    assert_receive {:inbound, :created}, 30_000
    # The consumer supervisor restarts the subscriber; the session resumes.
    assert_receive {:inbound, :duplicate}, 30_000
    refute_receive {:inbound, _}, 2_000

    assert [%{text: "exactly once"}] = inbound_activities(mqtt.id)
  end

  test "poison messages are published to the dead-letter topic", %{
    device: device,
    mqtt: mqtt,
    prefix: prefix
  } do
    start_consumer(mqtt)
    publish(device, "#{prefix}/in/bad", "{not json")
    publish(device, "#{prefix}/in/ok", ~s({"text": "fine"}))

    packet = next_message(device)
    assert packet.topic == "#{prefix}/dlq/#{mqtt.id}"
    body = Jason.decode!(packet.payload)
    assert body["error"] == "message body is not valid JSON"
    assert body["payload"] == "{not json"
    assert body["source"] == "#{prefix}/in/bad"
    assert body["channel_id"] == mqtt.id

    eventually = fn eventually, attempts ->
      case inbound_activities(mqtt.id) do
        [] when attempts > 0 -> Process.sleep(100) && eventually.(eventually, attempts - 1)
        activities -> activities
      end
    end

    assert [%{text: "fine"}] = eventually.(eventually, 300)
  end

  test "health probe", %{mqtt: mqtt} do
    assert Converger.Channels.Adapters.Mqtt.health_probe(mqtt) == :ok
  end
end
