defmodule Converger.Channels.Adapters.MqttTest do
  # Config, topics, client ids, message mapping and error classification of
  # the mqtt adapter, and its subscriber and publisher against
  # Converger.FakeMqttBroker. End to end against Mosquitto:
  # mqtt_integration_test.exs.
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.Activities.Activity
  alias Converger.Channels
  alias Converger.Channels.{Adapter, Broker, Consumers, DeliveryError}
  alias Converger.Channels.Adapters.Mqtt
  alias Converger.Channels.Broker.Publishers
  alias Converger.Channels.Mqtt.Packet
  alias Converger.FakeMqttBroker

  @config %{
    "host" => "mqtt.example.com",
    "topic_in" => "converger/in/+",
    "topic_out" => "converger/out/{conversation_id}"
  }

  defp validate(config, mode \\ "duplex"),
    do: Adapter.validate_config("mqtt", config, mode: mode)

  describe "config validation" do
    test "accepts a complete config" do
      assert validate(@config) == :ok

      assert validate(
               Map.merge(@config, %{
                 "port" => "8883",
                 "tls" => true,
                 "tls_verify" => "false",
                 "username" => "converger",
                 "password" => "s3cret",
                 "client_id" => "acme.prod",
                 "topic_dlq" => "dead/{tenant_id}/{channel_id}",
                 "qos" => 0,
                 "keepalive" => 60,
                 "derive_idempotency_key" => false
               })
             ) == :ok
    end

    test "requires the topic of the mode" do
      assert {:error, "mqtt config missing: topic_in (required in inbound mode)"} =
               validate(Map.delete(@config, "topic_in"), "inbound")

      assert {:error, "mqtt config missing: topic_out (required in outbound mode)"} =
               validate(Map.delete(@config, "topic_out"), "outbound")

      assert validate(Map.delete(@config, "topic_out"), "inbound") == :ok
      assert validate(Map.delete(@config, "topic_in"), "outbound") == :ok
    end

    test "checks the host, with the SSRF guard" do
      for {host, message} <- [
            {"mqtt://mqtt.example.com", "must be a host name"},
            {"mqtt.example.com:1883", "must be a host name"},
            {"private.test", "is not allowed"},
            {"127.0.0.1", "is not allowed"}
          ] do
        assert {:error, error} = validate(%{@config | "host" => host})
        assert error =~ message, "#{host}: #{error}"
      end

      assert {:error, "mqtt config missing: host"} = validate(Map.delete(@config, "host"))
    end

    test "checks topics and templates" do
      for {config, message} <- [
            {%{"topic_in" => "a/#/b"}, "'topic_in' must be a valid topic filter"},
            {%{"topic_out" => "out/+"}, "'topic_out' must be a topic name without"},
            {%{"topic_out" => "out/{user}"}, "unknown placeholders: user"},
            {%{"topic_out" => "converger/in/{conversation_id}"},
             "'topic_out' must not match topic_in"},
            {%{"topic_in" => "dead/#"}, "'topic_dlq' must not match topic_in"},
            {%{"topic_dlq" => "converger/in/x"}, "'topic_dlq' must not match topic_in"}
          ] do
        config =
          if config["topic_in"] == "dead/#",
            do: Map.merge(@config, %{"topic_in" => "dead/#", "topic_dlq" => "dead/x"}),
            else: Map.merge(@config, config)

        assert {:error, error} = validate(config)
        assert error =~ message, "#{inspect(config)}: #{error}"
      end
    end

    test "the default dead-letter topic must not match topic_in" do
      assert {:error, error} =
               validate(%{
                 @config
                 | "topic_in" => "converger/#",
                   "topic_out" => "replies/{conversation_id}"
               })

      assert error =~ "'topic_dlq' must not match topic_in"
    end

    test "checks numbers, client id and credentials" do
      for {key, value, message} <- [
            {"port", 0, "'port' must be an integer from 1 to 65535"},
            {"qos", 2, "'qos' must be an integer from 0 to 1"},
            {"keepalive", 1, "'keepalive' must be an integer from 5 to 3600"},
            {"client_id", "has space", "'client_id' must be 1 to 64"},
            {"password", "pw", "'password' needs a username"},
            {"tls_ca_cert", "not a pem", "'tls_ca_cert' must be PEM"}
          ] do
        assert {:error, error} = validate(Map.put(@config, key, value))
        assert error =~ message, "#{key}: #{error}"
      end
    end
  end

  test "capabilities and modes" do
    assert Adapter.capability?("mqtt", :consumer)
    assert Adapter.supported_modes("mqtt") == ~w(inbound outbound duplex)
    assert {:error, _} = Mqtt.parse_inbound(%{}, %{})
  end

  test "topic templates" do
    assert Mqtt.render("out/{conversation_id}/{tenant_id}", %{
             "conversation_id" => "c1",
             "tenant_id" => "t1"
           }) == "out/c1/t1"

    assert Mqtt.render("dlq/{channel_id}", %{}) == "dlq/00000000-0000-0000-0000-000000000000"
  end

  describe "client ids" do
    setup do
      %{channel: %{id: "0f0c6e8e-5a51-4f38-9d6c-2f3e2f8c1a10", config: @config}}
    end

    test "the subscriber keeps a persistent session per topic filter", %{channel: channel} do
      {:ok, options} = Mqtt.connection_options(channel, :subscriber)
      assert options[:clean_session] == false
      assert options[:subscriptions] == [{"converger/in/+", 1}]
      assert options[:port] == 1883
      assert options[:ssl] == false
      assert "converger-0f0c6e8e-5a51-4f38-9d6c-2f3e2f8c1a10-s" <> _ = options[:client_id]

      # Same filter, same session; another filter, another session.
      assert {:ok, ^options} = Mqtt.connection_options(channel, :subscriber)

      {:ok, other} =
        Mqtt.connection_options(put_in(channel.config["topic_in"], "x/#"), :subscriber)

      assert other[:client_id] != options[:client_id]
    end

    test "publishers and probes use clean sessions of their own", %{channel: channel} do
      channel = put_in(channel.config["client_id"], "acme")
      {:ok, publisher} = Mqtt.connection_options(channel, :publisher)
      {:ok, probe} = Mqtt.connection_options(channel, :probe)

      assert "acme-0f0c6e8e-5a51-4f38-9d6c-2f3e2f8c1a10-p" <> _ = publisher[:client_id]
      assert "acme-0f0c6e8e-5a51-4f38-9d6c-2f3e2f8c1a10-h" <> _ = probe[:client_id]
      assert publisher[:clean_session] and probe[:clean_session]
      refute Keyword.has_key?(publisher, :subscriptions)
    end

    test "TLS defaults to port 8883", %{channel: channel} do
      {:ok, options} = Mqtt.connection_options(put_in(channel.config["tls"], true), :publisher)
      assert options[:port] == 8883
      assert options[:ssl][:verify] == :verify_peer
    end

    test "a blocked host is a permanent error", %{channel: channel} do
      assert {:error, {:target_blocked, _}} =
               Mqtt.connection_options(put_in(channel.config["host"], "private.test"), :probe)
    end
  end

  test "the derived message id hashes topic and payload" do
    channel = %{config: @config}
    info = Mqtt.packet_info(channel, %{topic: "converger/in/a", payload: "{}"})
    assert info.source == "converger/in/a"
    assert info.message_id == Mqtt.derived_id("converger/in/a", "{}")
    assert byte_size(info.message_id) == 64

    assert Mqtt.packet_info(channel, %{topic: "converger/in/b", payload: "{}"}).message_id !=
             info.message_id

    no_derive = %{config: Map.put(@config, "derive_idempotency_key", "false")}
    assert Mqtt.packet_info(no_derive, %{topic: "t", payload: "{}"}).message_id == nil
  end

  test "error classification" do
    for reason <- [
          {:connection_refused, :not_authorized},
          {:connection_refused, :bad_username_or_password},
          {:invalid_topic, "a/+"},
          {:target_blocked, "nope"},
          {:invalid_config, "bad"}
        ] do
      refute Mqtt.normalize_error(reason).retryable?, inspect(reason)
    end

    for reason <- [
          :puback_timeout,
          {:connect_failed, :econnrefused},
          {:connection_refused, :server_unavailable},
          {:exit, :noproc}
        ] do
      assert Mqtt.normalize_error(reason).retryable?, inspect(reason)
    end

    error = DeliveryError.permanent("x")
    assert Mqtt.normalize_error(error) == error
  end

  describe "against a broker" do
    setup do
      webhook = Application.get_env(:converger, :webhook, [])

      Application.put_env(
        :converger,
        :webhook,
        Keyword.put(webhook, :allow_private_targets, true)
      )

      on_exit(fn -> Application.put_env(:converger, :webhook, webhook) end)

      broker = start_supervised!({FakeMqttBroker, self()})
      tenant = tenant_fixture()

      {:ok, channel} =
        Channels.create_channel(%{
          name: "mqtt-#{System.unique_integer([:positive])}",
          type: "mqtt",
          mode: "duplex",
          status: "active",
          tenant_id: tenant.id,
          config:
            Map.merge(@config, %{
              "host" => "127.0.0.1",
              "port" => FakeMqttBroker.port(broker)
            })
        })

      on_exit(fn ->
        Consumers.stop_consumer(channel.id)
        Publishers.stop(channel.id)
      end)

      %{broker: broker, channel: channel, tenant: tenant}
    end

    defp start_consumer(channel) do
      Ecto.Adapters.SQL.Sandbox.mode(Converger.Repo, {:shared, self()})
      {:ok, _pid} = Consumers.start_consumer(channel)
      assert_receive {:mqtt_client, session, {:connect, %{clean_session: false}}}
      assert_receive {:mqtt_client, ^session, {:subscribe, 1, [{"converger/in/+", 1}]}}
      session
    end

    test "the subscriber accepts a message and acknowledges it afterwards", %{channel: channel} do
      assert Broker.consumes?(channel)
      session = start_consumer(channel)

      payload = ~s({"text":"temperature 21C","participant":{"external_id":"sensor-1"}})
      FakeMqttBroker.push(session, Packet.publish("converger/in/sensor-1", payload, 1, 5))
      assert_receive {:mqtt_client, ^session, {:puback, 5}}, 5_000

      key = "mqtt:" <> Mqtt.derived_id("converger/in/sensor-1", payload)

      assert %Activity{text: "temperature 21C", sender: "sensor-1"} =
               activity =
               Repo.get_by(Activity, idempotency_key: key)

      assert activity.metadata["converger_broker"]["source"] == "converger/in/sensor-1"

      # The same message again (a redelivery): acknowledged, no new activity.
      FakeMqttBroker.push(
        session,
        Packet.publish("converger/in/sensor-1", payload, 1, 6, dup: true)
      )

      assert_receive {:mqtt_client, ^session, {:puback, 6}}, 5_000
      assert Repo.aggregate(from(a in Activity, where: a.idempotency_key == ^key), :count) == 1
    end

    test "a poison message is published to the dead-letter topic, then acknowledged", %{
      channel: channel
    } do
      session = start_consumer(channel)
      FakeMqttBroker.push(session, Packet.publish("converger/in/x", "{not json", 1, 9))

      assert_receive {:mqtt_client, publisher,
                      {:publish, %{topic: "converger/dlq/" <> channel_id, payload: body, qos: 1}}},
                     5_000

      assert channel_id == channel.id
      assert publisher != session

      assert %{
               "error" => "message body is not valid JSON",
               "payload" => "{not json",
               "source" => "converger/in/x",
               "channel_id" => ^channel_id
             } = Jason.decode!(body)

      assert_receive {:mqtt_client, ^session, {:puback, 9}}, 5_000
    end

    test "an activity is published to the conversation's topic", %{
      channel: channel,
      tenant: tenant
    } do
      conversation = conversation_fixture(tenant, channel)
      activity = activity_fixture(tenant, conversation, %{text: "on its way"})

      assert {:ok, %{provider_message_id: id, mqtt_topic: topic}} =
               Mqtt.deliver_activity(channel, activity)

      assert id == activity.id
      assert topic == "converger/out/#{conversation.id}"

      assert_receive {:mqtt_client, _session,
                      {:publish, %{topic: ^topic, qos: 1, payload: payload}}}

      envelope = Jason.decode!(payload)
      assert envelope["id"] == activity.id
      assert envelope["channel_id"] == channel.id
      assert envelope["text"] == "on its way"
    end

    test "a missing PUBACK fails the delivery (retryable)", %{
      channel: channel,
      tenant: tenant,
      broker: broker
    } do
      activity = activity_fixture(tenant, conversation_fixture(tenant, channel), %{text: "x"})
      FakeMqttBroker.set(broker, :puback, false)
      channel = %{channel | retry_policy: %{"timeout_ms" => 300}}

      assert {:error, :puback_timeout} = Mqtt.deliver_activity(channel, activity)
      assert Adapter.normalize_error(channel, :puback_timeout).retryable?
    end

    test "health probe", %{channel: channel, broker: broker} do
      assert Mqtt.health_probe(channel) == :ok
      assert_receive {:mqtt_client, _session, {:connect, %{client_id: client_id}}}
      assert client_id =~ "-h"

      FakeMqttBroker.set(broker, :connack_code, 4)

      assert {:error, {:connection_refused, :bad_username_or_password}} =
               Mqtt.health_probe(channel)
    end
  end
end
