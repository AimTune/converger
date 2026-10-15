defmodule Converger.Channels.Adapters.KafkaTest do
  # Config, consumer options, message mapping and error classification of
  # the kafka adapter, without a broker. End to end: kafka_integration_test.exs.
  use ExUnit.Case, async: true

  alias Converger.Channels.{Adapter, DeliveryError}
  alias Converger.Channels.Adapters.Kafka

  @config %{
    "brokers" => "kafka-1.example.com:9092, kafka-2.example.com:9093",
    "topic_in" => "crm.in",
    "topic_out" => "crm.out"
  }

  defp validate(config, mode \\ "duplex"),
    do: Adapter.validate_config("kafka", config, mode: mode)

  describe "config validation" do
    test "accepts a complete config" do
      assert validate(@config) == :ok

      assert validate(
               Map.merge(@config, %{
                 "group_id" => "crm",
                 "dlq_topic" => "crm.dead",
                 "start_offset" => "latest",
                 "concurrency" => "8",
                 "sasl_mechanism" => "scram_sha_512",
                 "sasl_username" => "converger",
                 "sasl_password" => "s3cret",
                 "tls" => "true",
                 "tls_verify" => false
               })
             ) == :ok
    end

    test "requires the topics of the mode" do
      assert {:error, "kafka config missing: topic_in (required in inbound mode)"} =
               validate(Map.delete(@config, "topic_in"), "inbound")

      assert {:error, "kafka config missing: topic_out (required in outbound mode)"} =
               validate(Map.delete(@config, "topic_out"), "outbound")

      assert {:error, "kafka config missing: topic_in, topic_out (required in duplex mode)"} =
               validate(Map.drop(@config, ["topic_in", "topic_out"]))

      assert validate(Map.delete(@config, "topic_out"), "inbound") == :ok
      assert validate(Map.delete(@config, "topic_in"), "outbound") == :ok
    end

    test "requires brokers as host:port pairs" do
      assert {:error, "kafka config missing: brokers"} = validate(Map.delete(@config, "brokers"))

      for brokers <- ["kafka", "kafka:x", "kafka:0", "kafka:70000", "a b:9092", " , "] do
        assert {:error, "kafka config 'brokers' " <> _} =
                 validate(%{@config | "brokers" => brokers}),
               "expected #{inspect(brokers)} to be rejected"
      end
    end

    test "parses brokers, including IPv6 literals" do
      assert Kafka.hosts(%{"brokers" => "a.example:9092,[2001:db8::1]:9093"}) ==
               {:ok, [{"a.example", 9092}, {"2001:db8::1", 9093}]}
    end

    test "rejects private broker hosts (SSRF guard)" do
      for brokers <- ["private.test:9092", "10.1.2.3:9092", "metadata.test:80"] do
        assert {:error, "kafka config 'brokers' host " <> message} =
                 validate(%{@config | "brokers" => brokers})

        assert message =~ "is not allowed"
      end
    end

    test "rejects invalid topic names and a dead-letter topic equal to topic_in" do
      assert {:error, "kafka config 'topic_in' must be a Kafka topic name" <> _} =
               validate(%{@config | "topic_in" => "bad topic"})

      assert {:error, "kafka config 'topic_out' must be a Kafka topic name" <> _} =
               validate(%{@config | "topic_out" => ".."})

      assert {:error, "kafka config 'dlq_topic' must differ from topic_in"} =
               validate(Map.put(@config, "dlq_topic", "crm.in"))
    end

    test "checks SASL, start offset, concurrency and TLS settings" do
      assert {:error, "kafka config 'sasl_mechanism' must be one of: " <> _} =
               validate(Map.put(@config, "sasl_mechanism", "gssapi"))

      assert {:error, "kafka config 'sasl_mechanism' needs sasl_username and sasl_password"} =
               validate(Map.put(@config, "sasl_mechanism", "plain"))

      assert {:error, "kafka config 'sasl_username' / 'sasl_password' need a sasl_mechanism"} =
               validate(Map.put(@config, "sasl_username", "u"))

      assert {:error, "kafka config 'start_offset' must be one of: " <> _} =
               validate(Map.put(@config, "start_offset", "beginning"))

      assert {:error, "kafka config 'concurrency' must be a positive integer of at most 64"} =
               validate(Map.put(@config, "concurrency", "65"))

      assert {:error, "kafka config 'tls_ca_cert' must be PEM-encoded certificates"} =
               validate(Map.put(@config, "tls_ca_cert", "not a pem"))
    end

    test "the SASL password is a secret and is redacted" do
      assert %{secret: true} =
               Enum.find(Kafka.config_schema(), &(&1.name == "sasl_password"))

      assert Converger.Secrets.redact(%{"sasl_password" => "p"}) == %{
               "sasl_password" => "[REDACTED]"
             }
    end
  end

  describe "client config" do
    test "SASL and TLS" do
      config =
        Map.merge(@config, %{
          "sasl_mechanism" => "scram_sha_256",
          "sasl_username" => "u",
          "sasl_password" => "p",
          "tls" => true
        })

      client = Kafka.client_config(config)
      assert client[:sasl] == {:scram_sha_256, "u", "p"}
      assert client[:ssl][:verify] == :verify_peer
      assert client[:ssl][:server_name_indication] == ~c"kafka-1.example.com"
      assert is_list(client[:ssl][:cacerts])

      assert Kafka.client_config(Map.put(config, "tls_verify", "false"))[:ssl] == [
               verify: :verify_none
             ]

      assert Kafka.client_config(@config)[:sasl] == :undefined
      assert Kafka.client_config(@config)[:ssl] == false
    end
  end

  describe "consumer" do
    setup do
      %{channel: %{id: Ecto.UUID.generate(), type: "kafka", config: @config}}
    end

    test "consumes topic_in in group converger-<channel id> from the earliest offset", %{
      channel: channel
    } do
      assert {:ok, options} = Kafka.consumer_options(channel)
      assert [module: {BroadwayKafka.Producer, producer}, concurrency: 1] = options[:producer]
      assert producer[:hosts] == [{"kafka-1.example.com", 9092}, {"kafka-2.example.com", 9093}]
      assert producer[:group_id] == "converger-#{channel.id}"
      assert producer[:topics] == ["crm.in"]
      assert producer[:offset_reset_policy] == :earliest
      assert producer[:offset_commit_on_ack] == true
      assert options[:processors] == [default: [concurrency: 4]]
    end

    test "a configured group, offset and concurrency", %{channel: channel} do
      config =
        Map.merge(@config, %{"group_id" => "g", "start_offset" => "latest", "concurrency" => 2})

      {:ok, options} = Kafka.consumer_options(%{channel | config: config})
      [module: {_, producer}, concurrency: 1] = options[:producer]
      assert producer[:group_id] == "g"
      assert producer[:offset_reset_policy] == :latest
      assert options[:processors] == [default: [concurrency: 2]]
    end

    test "needs topic_in", %{channel: channel} do
      assert {:error, "kafka channel has no topic_in"} =
               Kafka.consumer_options(%{channel | config: Map.delete(@config, "topic_in")})
    end

    test "maps a message: the broker id is topic/partition/offset", %{channel: channel} do
      message = %Broadway.Message{
        data: ~s({"text":"hi"}),
        metadata: %{
          topic: "crm.in",
          partition: 2,
          offset: 41,
          key: "c-1",
          ts: 0,
          headers: [{"h", "v"}]
        },
        acknowledger: Broadway.NoopAcknowledger.init()
      }

      assert Kafka.message_info(channel, message) == %{
               payload: ~s({"text":"hi"}),
               message_id: "crm.in/2/41",
               source: "crm.in/2/41",
               key: "c-1",
               headers: [{"h", "v"}]
             }
    end

    test "the dead-letter topic defaults to <topic_in>.dlq" do
      assert Kafka.dlq_topic(@config) == "crm.in.dlq"
      assert Kafka.dlq_topic(Map.put(@config, "dlq_topic", "dead")) == "dead"
    end
  end

  describe "delivery" do
    test "an activity consumed from the channel is not produced back to it" do
      channel = %{id: Ecto.UUID.generate(), type: "kafka", config: @config, retry_policy: %{}}

      activity = %Converger.Activities.Activity{
        id: Ecto.UUID.generate(),
        conversation_id: Ecto.UUID.generate(),
        metadata: %{"converger_broker" => %{"channel_id" => channel.id}}
      }

      assert {:ok, %{skipped: _}} = Kafka.deliver_activity(channel, activity)
    end

    test "without topic_out the delivery fails permanently" do
      channel = %{
        id: Ecto.UUID.generate(),
        type: "kafka",
        config: Map.delete(@config, "topic_out"),
        retry_policy: %{}
      }

      activity = %Converger.Activities.Activity{id: Ecto.UUID.generate(), metadata: %{}}

      assert {:error, %DeliveryError{retryable?: false}} =
               Kafka.deliver_activity(channel, activity)
    end
  end

  describe "error classification" do
    test "authorization, SASL and guard errors are permanent, the rest is retried" do
      for reason <- [
            :topic_authorization_failed,
            [{{"k", 9092}, {{:sasl_authentication_failed, "bad"}, []}}],
            {:target_blocked, "host 10.0.0.1 is not allowed"},
            {:shutdown, {:failed_to_start_child, :x, :message_too_large}}
          ] do
        assert %DeliveryError{retryable?: false} = Kafka.normalize_error(reason)
      end

      for reason <- [:timeout, :leader_not_available, {:producer_down, :noproc}, :econnrefused] do
        assert %DeliveryError{retryable?: true} = Kafka.normalize_error(reason)
      end
    end
  end

  test "inbound webhooks are refused" do
    assert {:error, _} = Kafka.parse_inbound(%{}, %{})
  end

  test "capabilities and modes" do
    assert :consumer in Kafka.capabilities()
    assert Kafka.supported_modes() == ~w(inbound outbound duplex)
  end
end
