defmodule Converger.Channels.Adapters.RabbitMQTest do
  # Config, consumer options, message mapping and error classification of
  # the rabbitmq adapter, without a broker. End to end:
  # rabbitmq_integration_test.exs.
  use ExUnit.Case, async: true

  alias Converger.Channels.{Adapter, DeliveryError}
  alias Converger.Channels.Adapters.RabbitMQ

  @config %{
    "url" => "amqp://rabbit.example.com:5672/%2F",
    "username" => "converger",
    "password" => "s3cret",
    "queue" => "crm.in",
    "exchange" => "crm",
    "routing_key" => "crm.out"
  }

  defp validate(config, mode \\ "duplex"),
    do: Adapter.validate_config("rabbitmq", config, mode: mode)

  describe "config validation" do
    test "accepts a complete config" do
      assert validate(@config) == :ok

      assert validate(
               Map.merge(@config, %{
                 "url" => "amqps://rabbit.example.com/prod",
                 "dlq_queue" => "crm.dead",
                 "declare" => "true",
                 "prefetch_count" => "50",
                 "concurrency" => 2,
                 "tls_verify" => true
               })
             ) == :ok
    end

    test "requires the queue or routing key of the mode" do
      assert {:error, "rabbitmq config missing: queue (required in inbound mode)"} =
               validate(Map.delete(@config, "queue"), "inbound")

      assert {:error, "rabbitmq config missing: routing_key (required in outbound mode)"} =
               validate(Map.delete(@config, "routing_key"), "outbound")

      assert validate(Map.delete(@config, "routing_key"), "inbound") == :ok
      assert validate(Map.delete(@config, "queue"), "outbound") == :ok
    end

    test "checks the URL" do
      for {url, message} <- [
            {"http://rabbit.example.com", "must be an amqp:// or amqps:// URL"},
            {"amqp://", "must include a host"},
            {"amqp://user:pw@rabbit.example.com", "must not contain credentials"},
            {"amqp://rabbit.example.com/a/b", "must be URL-encoded"},
            {"amqp://rabbit.example.com?heartbeat=5", "must not have a query"},
            {"amqp://private.test", "is not allowed"}
          ] do
        assert {:error, error} = validate(%{@config | "url" => url})
        assert error =~ message, "#{url}: #{error}"
      end
    end

    test "checks names, credentials and limits" do
      assert {:error, "rabbitmq config 'dlq_queue' must differ from queue"} =
               validate(Map.put(@config, "dlq_queue", "crm.in"))

      assert {:error, "rabbitmq config 'queue' must be a string of at most 255 bytes"} =
               validate(%{@config | "queue" => String.duplicate("q", 256)})

      assert {:error, "rabbitmq config 'password' needs a username"} =
               validate(Map.delete(@config, "username"))

      assert {:error, "rabbitmq config 'prefetch_count' must be a positive integer" <> _} =
               validate(Map.put(@config, "prefetch_count", "0"))

      assert {:error, "rabbitmq config 'concurrency' must be a positive integer" <> _} =
               validate(Map.put(@config, "concurrency", 100))
    end

    test "the password is a secret and is redacted" do
      assert %{secret: true} = Enum.find(RabbitMQ.config_schema(), &(&1.name == "password"))
      assert Converger.Secrets.redact(%{"password" => "p"}) == %{"password" => "[REDACTED]"}
    end
  end

  describe "connection options" do
    test "host, port, virtual host and credentials" do
      assert {:ok, options} = RabbitMQ.connection_options(@config)
      assert options[:host] == "rabbit.example.com"
      assert options[:port] == 5672
      assert options[:virtual_host] == "/"
      assert options[:username] == "converger"
      assert options[:password] == "s3cret"
      refute Keyword.has_key?(options, :ssl_options)
    end

    test "amqps uses TLS on 5671; the virtual host is URL-decoded" do
      config = %{@config | "url" => "amqps://rabbit.example.com/tenant%2Fprod"}
      assert {:ok, options} = RabbitMQ.connection_options(config)
      assert options[:port] == 5671
      assert options[:virtual_host] == "tenant/prod"
      assert options[:ssl_options][:verify] == :verify_peer

      config = Map.put(config, "tls_verify", false)
      assert {:ok, options} = RabbitMQ.connection_options(config)
      assert options[:ssl_options] == [verify: :verify_none]
    end

    test "without a username the broker default applies" do
      config = Map.drop(@config, ["username", "password"])
      assert {:ok, options} = RabbitMQ.connection_options(config)
      refute Keyword.has_key?(options, :username)
    end
  end

  describe "consumer" do
    setup do
      %{channel: %{id: Ecto.UUID.generate(), type: "rabbitmq", config: @config}}
    end

    test "consumes the queue with message ids and headers", %{channel: channel} do
      assert {:ok, options} = RabbitMQ.consumer_options(channel)
      assert [module: {BroadwayRabbitMQ.Producer, producer}, concurrency: 1] = options[:producer]
      assert producer[:queue] == "crm.in"
      assert producer[:qos] == [prefetch_count: 10]
      assert :message_id in producer[:metadata]
      assert :headers in producer[:metadata]
      refute Keyword.has_key?(producer, :declare)
      assert producer[:after_connect].(:no_channel) == :ok
      assert options[:processors] == [default: [concurrency: 1]]
    end

    test "declare: true declares the queue", %{channel: channel} do
      config = Map.merge(@config, %{"declare" => true, "prefetch_count" => "25"})
      {:ok, options} = RabbitMQ.consumer_options(%{channel | config: config})
      [module: {_, producer}, concurrency: 1] = options[:producer]
      assert producer[:declare] == [durable: true]
      assert producer[:qos] == [prefetch_count: 25]
    end

    test "maps a message: the broker id is the message_id property", %{channel: channel} do
      message = %Broadway.Message{
        data: "{}",
        metadata: %{
          message_id: "m-1",
          routing_key: "crm.in",
          headers: [{"x-trace", :longstr, "t"}, {"n", :long, 1}]
        },
        acknowledger: Broadway.NoopAcknowledger.init()
      }

      assert RabbitMQ.message_info(channel, message) == %{
               payload: "{}",
               message_id: "m-1",
               source: "crm.in/m-1",
               key: "crm.in",
               headers: [{"x-trace", "t"}]
             }

      without_id = %{message | metadata: %{message_id: :undefined, headers: :undefined}}

      assert %{message_id: nil, source: "crm.in", headers: []} =
               RabbitMQ.message_info(channel, without_id)
    end

    test "the dead-letter queue defaults to <queue>.dlq" do
      assert RabbitMQ.dlq_queue(@config) == "crm.in.dlq"
    end
  end

  describe "delivery" do
    test "an activity consumed from the channel is not published back to it" do
      channel = %{id: Ecto.UUID.generate(), type: "rabbitmq", config: @config, retry_policy: %{}}

      activity = %Converger.Activities.Activity{
        id: Ecto.UUID.generate(),
        metadata: %{"converger_broker" => %{"channel_id" => channel.id}}
      }

      assert {:ok, %{skipped: _}} = RabbitMQ.deliver_activity(channel, activity)
    end
  end

  describe "error classification" do
    test "access and guard errors are permanent, the rest is retried" do
      for reason <- [
            :access_refused,
            {:auth_failure, ~c"ACCESS_REFUSED"},
            {:target_blocked, "x"},
            :not_allowed
          ] do
        assert %DeliveryError{retryable?: false} = RabbitMQ.normalize_error(reason)
      end

      for reason <- [:econnrefused, :nacked, :confirm_timeout, {:exit, :noproc}] do
        assert %DeliveryError{retryable?: true} = RabbitMQ.normalize_error(reason)
      end
    end
  end
end
