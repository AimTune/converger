defmodule Converger.Channels.Adapters.RedisStreamsTest do
  # Config, connection options, consumer options, message mapping and error
  # classification of the redis_streams adapter, without a server. End to
  # end: redis_streams_integration_test.exs.
  use ExUnit.Case, async: true

  alias Converger.Channels.{Adapter, DeliveryError}
  alias Converger.Channels.Adapters.RedisStreams
  alias Converger.Channels.Broker.{RedisPublisher, RedisStreamsProducer}

  @config %{
    "url" => "redis://redis.example.com:6379/2",
    "username" => "converger",
    "password" => "s3cret",
    "stream_in" => "crm.in",
    "stream_out" => "crm.out"
  }

  defp validate(config, mode \\ "duplex"),
    do: Adapter.validate_config("redis_streams", config, mode: mode)

  describe "config validation" do
    test "accepts a complete config" do
      assert validate(@config) == :ok

      assert validate(
               Map.merge(@config, %{
                 "url" => "rediss://redis.example.com",
                 "group" => "crm-group",
                 "dlq_stream" => "crm.dead",
                 "maxlen" => "100000",
                 "start_id" => "latest",
                 "batch_size" => 100,
                 "concurrency" => "2",
                 "tls_verify" => false
               })
             ) == :ok

      assert validate(Map.delete(@config, "username")) == :ok
    end

    test "requires the stream of the mode" do
      assert {:error, "redis_streams config missing: stream_in (required in inbound mode)"} =
               validate(Map.delete(@config, "stream_in"), "inbound")

      assert {:error, "redis_streams config missing: stream_out (required in outbound mode)"} =
               validate(Map.delete(@config, "stream_out"), "outbound")

      assert validate(Map.delete(@config, "stream_out"), "inbound") == :ok
      assert validate(Map.delete(@config, "stream_in"), "outbound") == :ok
    end

    test "checks the URL" do
      for {url, message} <- [
            {"http://redis.example.com", "must be a redis:// or rediss:// URL"},
            {"redis://", "must include a host"},
            {"redis://:pw@redis.example.com", "must not contain credentials"},
            {"redis://redis.example.com/db", "database must be a number"},
            {"redis://redis.example.com?db=1", "must not have a query"},
            {"redis://private.test", "is not allowed"}
          ] do
        assert {:error, error} = validate(%{@config | "url" => url})
        assert error =~ message, "#{url}: #{error}"
      end
    end

    test "checks keys, credentials and limits" do
      assert {:error, "redis_streams config 'dlq_stream' must differ from stream_in"} =
               validate(Map.put(@config, "dlq_stream", "crm.in"))

      assert {:error, "redis_streams config 'stream_out' must differ from stream_in"} =
               validate(%{@config | "stream_out" => "crm.in"})

      assert {:error, "redis_streams config 'stream_in' must not contain whitespace"} =
               validate(%{@config | "stream_in" => "crm in"})

      assert {:error, "redis_streams config 'group' must be a string of at most 512 bytes"} =
               validate(Map.put(@config, "group", String.duplicate("g", 513)))

      assert {:error, "redis_streams config 'username' needs a password"} =
               validate(Map.delete(@config, "password"))

      assert {:error, "redis_streams config 'start_id' must be one of: earliest, latest"} =
               validate(Map.put(@config, "start_id", "0"))

      assert {:error, "redis_streams config 'maxlen' must be a positive integer" <> _} =
               validate(Map.put(@config, "maxlen", "-1"))

      assert {:error, "redis_streams config 'concurrency' must be a positive integer" <> _} =
               validate(Map.put(@config, "concurrency", 100))
    end

    test "the password is a secret" do
      assert %{secret: true} = Enum.find(RedisStreams.config_schema(), &(&1.name == "password"))
    end
  end

  describe "connection options" do
    test "host, port, database and credentials" do
      assert {:ok, options} = RedisStreams.connection_options(@config)
      assert options[:host] == "redis.example.com"
      assert options[:port] == 6379
      assert options[:database] == 2
      assert options[:username] == "converger"
      assert options[:password] == "s3cret"
      assert options[:sync_connect] == true
      refute Keyword.has_key?(options, :ssl)
    end

    test "rediss uses TLS; a password alone uses the default user" do
      config = %{"url" => "rediss://redis.example.com", "password" => "p"}
      assert {:ok, options} = RedisStreams.connection_options(config)
      assert options[:port] == 6379
      assert options[:database] == 0
      assert options[:ssl] == true
      assert options[:socket_opts][:verify] == :verify_peer
      assert options[:password] == "p"
      refute Keyword.has_key?(options, :username)
    end
  end

  describe "consumer" do
    setup do
      %{channel: %{id: Ecto.UUID.generate(), type: "redis_streams", config: @config}}
    end

    test "reads stream_in in a consumer group named per node", %{channel: channel} do
      assert {:ok, options} = RedisStreams.consumer_options(channel)

      assert [module: {RedisStreamsProducer, producer}, concurrency: 1] = options[:producer]
      assert producer[:stream] == "crm.in"
      assert producer[:group] == "converger-#{channel.id}"
      assert producer[:consumer] == Atom.to_string(node())
      assert producer[:start_id] == "0"
      assert producer[:batch_size] == 10
      assert options[:processors] == [default: [concurrency: 1]]

      config = Map.merge(@config, %{"group" => "g", "start_id" => "latest"})
      {:ok, options} = RedisStreams.consumer_options(%{channel | config: config})
      [module: {_, producer}, concurrency: 1] = options[:producer]
      assert producer[:group] == "g"
      assert producer[:start_id] == "$"
    end

    test "maps an entry: the broker id is stream/entry id", %{channel: channel} do
      message = %Broadway.Message{
        data: [{"payload", "{}"}, {"trace-id", "t"}],
        metadata: %{id: "1700000000000-0", stream: "crm.in"},
        acknowledger: Broadway.NoopAcknowledger.init()
      }

      assert RedisStreams.message_info(channel, message) == %{
               payload: "{}",
               message_id: "crm.in/1700000000000-0",
               source: "crm.in/1700000000000-0",
               key: nil,
               headers: [{"trace-id", "t"}]
             }

      # No payload field: dead-lettered as "message has no payload".
      assert %{payload: nil, headers: [{"text", "hi"}]} =
               RedisStreams.message_info(channel, %{message | data: [{"text", "hi"}]})

      assert Converger.Channels.Broker.Envelope.decode(nil, channel) ==
               {:error, "message has no payload"}
    end

    test "parses stream entries and skips deleted ones" do
      assert RedisStreamsProducer.parse_entries([
               ["1-0", ["payload", "{}", "a", "b"]],
               ["2-0", nil],
               nil
             ]) == [{"1-0", [{"payload", "{}"}, {"a", "b"}]}]

      assert RedisStreamsProducer.parse_entries(nil) == []
    end

    test "recovery claims the group's pending entries, then new entries are read" do
      assert RedisStreamsProducer.xautoclaim_command("s", "g", "c", "0-0", 10) ==
               ~w(XAUTOCLAIM s g c 0 0-0 COUNT 10)

      assert RedisStreamsProducer.xreadgroup_command("s", "g", "c", 10, 2000) ==
               ~w(XREADGROUP GROUP g c COUNT 10 BLOCK 2000 STREAMS s >)
    end

    test "the dead-letter stream defaults to <stream_in>.dlq" do
      assert RedisStreams.dlq_stream(@config) == "crm.in.dlq"
    end
  end

  describe "delivery" do
    test "XADD with and without MAXLEN" do
      assert RedisPublisher.xadd_command("s", ["payload", "{}"], nil) ==
               ~w(XADD s * payload {})

      assert RedisPublisher.xadd_command("s", ["payload", "{}"], 1000) ==
               ~w(XADD s MAXLEN ~ 1000 * payload {})
    end

    test "an activity consumed from the channel is not appended back to it" do
      channel = %{
        id: Ecto.UUID.generate(),
        type: "redis_streams",
        config: @config,
        retry_policy: %{}
      }

      activity = %Converger.Activities.Activity{
        id: Ecto.UUID.generate(),
        metadata: %{"converger_broker" => %{"channel_id" => channel.id}}
      }

      assert {:ok, %{skipped: _}} = RedisStreams.deliver_activity(channel, activity)
    end
  end

  describe "error classification" do
    test "type, ACL and guard errors are permanent, the rest is retried" do
      for reason <- [
            %Redix.Error{message: "WRONGTYPE Operation against a key holding the wrong kind"},
            %Redix.Error{message: "NOPERM this user has no permissions"},
            %Redix.Error{message: "WRONGPASS invalid username-password pair"},
            {:target_blocked, "x"}
          ] do
        assert %DeliveryError{retryable?: false} = RedisStreams.normalize_error(reason)
      end

      for reason <- [
            %Redix.ConnectionError{reason: :closed},
            %Redix.Error{message: "LOADING Redis is loading the dataset in memory"},
            {:exit, :noproc}
          ] do
        assert %DeliveryError{retryable?: true} = RedisStreams.normalize_error(reason)
      end
    end
  end
end
