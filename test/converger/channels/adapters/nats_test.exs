defmodule Converger.Channels.Adapters.NatsTest do
  # Config, connection settings, consumer options, message mapping and error
  # classification of the nats adapter, without a server. End to end:
  # nats_integration_test.exs.
  use ExUnit.Case, async: true

  alias Converger.Channels.{Adapter, DeliveryError}
  alias Converger.Channels.Adapters.Nats
  alias Converger.Channels.Broker.{NatsProducer, NatsPublisher}

  @seed "SUAMLK2ZNL35WSMW37E7UD4VZ7ELPKW7DHC3BWBSD2GCZ7IUQQXZIORRBU"

  @creds """
  -----BEGIN NATS USER JWT-----
  eyJ0eXAiOiJKV1QiLCJhbGciOiJlZDI1NTE5LW5rZXkifQ.eyJzdWIiOiJVQUJDIn0.c2ln
  ------END NATS USER JWT------

  ************************* IMPORTANT *************************
  NKEY Seed printed below can be used to sign and prove identity.

  -----BEGIN USER NKEY SEED-----
  #{@seed}
  ------END USER NKEY SEED------
  """

  @config %{
    "servers" => "nats://nats.example.com:4222",
    "stream" => "CRM",
    "subject_in" => "crm.in",
    "subject_out" => "crm.out",
    "username" => "converger",
    "password" => "s3cret"
  }

  defp validate(config, mode \\ "duplex"),
    do: Adapter.validate_config("nats", config, mode: mode)

  describe "config validation" do
    test "accepts a complete config" do
      assert validate(@config) == :ok

      assert validate(
               Map.merge(@config, %{
                 "servers" => "tls://nats-1.example.com, nats-2.example.com:4223",
                 "subject_out" => "crm.out.{conversation_id}",
                 "durable_name" => "crm-consumer",
                 "dlq_subject" => "crm.dead",
                 "declare" => "true",
                 "deliver_policy" => "new",
                 "batch_size" => "50",
                 "ack_wait_seconds" => 600,
                 "concurrency" => 2,
                 "tls" => true,
                 "tls_verify" => true
               })
             ) == :ok
    end

    test "requires the stream and subject of the mode" do
      assert {:error, "nats config missing: stream, subject_in (required in inbound mode)"} =
               validate(Map.drop(@config, ["stream", "subject_in"]), "inbound")

      assert {:error, "nats config missing: subject_out (required in outbound mode)"} =
               validate(Map.delete(@config, "subject_out"), "outbound")

      assert validate(Map.delete(@config, "subject_out"), "inbound") == :ok
      assert validate(Map.drop(@config, ["stream", "subject_in"]), "outbound") == :ok
    end

    test "checks the servers" do
      for {servers, message} <- [
            {"http://nats.example.com", "must be nats:// or tls:// URLs"},
            {"nats://", "with a host"},
            {"nats://user:pw@nats.example.com", "must not contain credentials"},
            {"nats://nats.example.com/path", "host and port only"},
            {"nats://private.test", "is not allowed"},
            {" , ", "at least one server"}
          ] do
        assert {:error, error} = validate(%{@config | "servers" => servers})
        assert error =~ message, "#{servers}: #{error}"
      end
    end

    test "checks subjects" do
      for {field, value, message} <- [
            {"subject_in", "crm..in", "must be a NATS subject"},
            {"subject_in", "crm in", "must be a NATS subject"},
            {"subject_in", "crm.>.x", "must be a NATS subject"},
            {"subject_out", "crm.*", "without wildcards"},
            {"dlq_subject", "crm.>", "without wildcards"}
          ] do
        assert {:error, error} = validate(Map.put(@config, field, value))
        assert error =~ message, "#{field} #{value}: #{error}"
      end

      # Wildcard inbound subjects need an explicit dead-letter subject that
      # they do not match (the consumer would read its own dead letters).
      assert {:error, "nats config 'dlq_subject' is required when subject_in has wildcards"} =
               validate(%{@config | "subject_in" => "crm.in.*"})

      assert validate(
               Map.merge(@config, %{"subject_in" => "crm.in.*", "dlq_subject" => "crm.dlq"})
             ) ==
               :ok

      assert {:error, "nats config 'dlq_subject' must not match subject_in"} =
               validate(
                 Map.merge(@config, %{"subject_in" => "crm.>", "dlq_subject" => "crm.dlq"})
               )

      assert {:error, "nats config 'subject_out' must not match subject_in"} =
               validate(
                 Map.merge(@config, %{"subject_in" => "crm.*", "dlq_subject" => "dlq.crm"})
               )
    end

    test "checks names, choices and limits" do
      assert {:error, "nats config 'stream' must be a name" <> _} =
               validate(%{@config | "stream" => "crm.stream"})

      assert {:error, "nats config 'durable_name' must be a name" <> _} =
               validate(Map.put(@config, "durable_name", "a b"))

      assert {:error, "nats config 'deliver_policy' must be one of: all, new"} =
               validate(Map.put(@config, "deliver_policy", "last"))

      assert {:error, "nats config 'batch_size' must be a positive integer" <> _} =
               validate(Map.put(@config, "batch_size", "0"))

      assert {:error, "nats config 'concurrency' must be a positive integer" <> _} =
               validate(Map.put(@config, "concurrency", 100))
    end

    test "checks authentication" do
      without_user = Map.drop(@config, ["username", "password"])

      assert validate(Map.put(without_user, "token", "t0k")) == :ok
      assert validate(Map.put(without_user, "nkey_seed", @seed)) == :ok
      assert validate(Map.put(without_user, "creds", @creds)) == :ok

      assert {:error, "nats config must use one authentication method" <> _} =
               validate(Map.put(@config, "token", "t0k"))

      assert {:error, "nats config 'password' needs a username"} =
               validate(Map.delete(@config, "username"))

      assert {:error, "nats config 'nkey_seed' must be an NKey user seed (SU...)"} =
               validate(Map.put(without_user, "nkey_seed", "SUAXX"))

      assert {:error, "nats config 'creds' must be the contents of a NATS .creds file"} =
               validate(Map.put(without_user, "creds", "not a creds file"))
    end

    test "credentials are secrets and are redacted" do
      schema = Nats.config_schema()

      for name <- ~w(password token nkey_seed) do
        assert %{secret: true} = Enum.find(schema, &(&1.name == name))
      end

      assert Converger.Secrets.redact(%{
               "password" => "p",
               "token" => "t",
               "nkey_seed" => @seed,
               "creds" => @creds
             }) == %{
               "password" => "[REDACTED]",
               "token" => "[REDACTED]",
               "nkey_seed" => "[REDACTED]",
               "creds" => "[REDACTED]"
             }
    end
  end

  describe "connection settings" do
    test "servers, TLS and user/password" do
      assert {:ok, [server, second]} =
               Nats.servers(%{"servers" => "nats-1:4222,tls://[::1]:4443"})

      assert server == %{host: "nats-1", port: 4222, tls: false}
      assert second == %{host: "::1", port: 4443, tls: true}

      settings = Nats.connection_settings(@config, server)
      assert settings.host == "nats-1"
      assert settings.tls == false
      assert settings.no_responders == true
      assert settings.username == "converger"
      assert settings.password.() == "s3cret"

      tls = Nats.connection_settings(Map.put(@config, "tls_verify", false), second)
      assert tls.tls == true
      assert tls.ssl_opts == [verify: :verify_none]
      assert :inet6 in tls.tcp_opts
    end

    test "token, nkey seed and creds" do
      server = %{host: "nats", port: 4222, tls: false}

      assert %{token: token} = Nats.connection_settings(%{"token" => "t0k"}, server)
      assert token.() == "t0k"

      assert %{nkey_seed: seed} = Nats.connection_settings(%{"nkey_seed" => @seed}, server)
      assert seed.() == @seed

      assert %{jwt: jwt, nkey_seed: seed} = Nats.connection_settings(%{"creds" => @creds}, server)
      assert jwt =~ "eyJ0eXAi"
      assert seed.() == @seed
    end
  end

  describe "subjects" do
    test "wildcard matching" do
      assert Nats.subject_matches?("crm.in", "crm.in")
      assert Nats.subject_matches?("crm.*", "crm.in")
      assert Nats.subject_matches?("crm.>", "crm.in.dlq")
      refute Nats.subject_matches?("crm.*", "crm.in.dlq")
      refute Nats.subject_matches?("crm.in", "crm.in.dlq")
      refute Nats.subject_matches?("crm.>", "crm")
    end

    test "the outbound subject can carry the conversation id" do
      assert Nats.subject_out(%{"subject_out" => "crm.out.{conversation_id}"}, "c-1") ==
               "crm.out.c-1"

      assert Nats.subject_out(%{"subject_out" => "crm.out"}, "c-1") == "crm.out"
    end
  end

  describe "consumer" do
    setup do
      %{channel: %{id: Ecto.UUID.generate(), type: "nats", config: @config}}
    end

    test "pulls from a durable consumer of the stream", %{channel: channel} do
      assert {:ok, options} = Nats.consumer_options(channel)
      assert [module: {NatsProducer, producer}, concurrency: 1] = options[:producer]
      assert producer[:stream] == "CRM"
      assert producer[:subject] == "crm.in"
      assert producer[:durable_name] == "converger-#{channel.id}"
      assert producer[:dlq_subject] == "crm.in.dlq"
      assert producer[:declare] == false
      assert producer[:deliver_policy] == :all
      assert producer[:ack_wait_ms] == 300_000
      assert producer[:batch_size] == 10
      assert options[:processors] == [default: [concurrency: 1]]
    end

    test "without a stream there is no consumer", %{channel: channel} do
      assert {:error, "nats channel has no stream or subject_in"} =
               Nats.consumer_options(%{channel | config: Map.delete(@config, "stream")})
    end

    test "maps a message: the broker id is stream/sequence", %{channel: channel} do
      msg = %{
        gnat: self(),
        topic: "crm.in",
        body: "{}",
        sid: 1,
        reply_to: "$JS.ACK.CRM.converger.2.41.40.1760000000000000000.0",
        headers: [{"trace-id", "t"}]
      }

      message = NatsProducer.to_broadway_message(msg, %{stream: "CRM", conn: self()})
      assert message.metadata.stream_seq == 41
      assert message.metadata.num_delivered == 2

      assert Nats.message_info(channel, message) == %{
               payload: "{}",
               message_id: "CRM/41",
               source: "CRM/41",
               key: "crm.in",
               headers: [{"trace-id", "t"}]
             }
    end

    test "the dead-letter subject defaults to <subject_in>.dlq" do
      assert Nats.dlq_subject(@config) == "crm.in.dlq"
      assert Nats.dlq_subject(Map.put(@config, "dlq_subject", "x.dlq")) == "x.dlq"
    end
  end

  describe "delivery" do
    test "an activity consumed from the channel is not published back to it" do
      channel = %{id: Ecto.UUID.generate(), type: "nats", config: @config, retry_policy: %{}}

      activity = %Converger.Activities.Activity{
        id: Ecto.UUID.generate(),
        metadata: %{"converger_broker" => %{"channel_id" => channel.id}}
      }

      assert {:ok, %{skipped: _}} = Nats.deliver_activity(channel, activity)
    end

    test "publish acknowledgements" do
      assert {:ok, %{stream: "CRM", seq: 7, duplicate: false}} =
               NatsPublisher.publish_ack(~s({"stream":"CRM","seq":7}))

      assert {:ok, %{duplicate: true}} =
               NatsPublisher.publish_ack(~s({"stream":"CRM","seq":7,"duplicate":true}))

      assert {:error, {:bad_request, "message size exceeds maximum allowed"}} =
               NatsPublisher.publish_ack(
                 ~s({"error":{"code":400,"err_code":10054,"description":"message size exceeds maximum allowed"}})
               )

      assert {:error, {:jetstream, 503, _}} =
               NatsPublisher.publish_ack(~s({"error":{"code":503,"description":"unavailable"}}))
    end
  end

  describe "error classification" do
    test "bad requests, oversized messages and guard errors are permanent" do
      for reason <- [
            {:bad_request, "message size exceeds maximum allowed"},
            :max_payload_exceeded,
            {:target_blocked, "x"},
            {:invalid_config, "x"}
          ] do
        assert %DeliveryError{retryable?: false} = Nats.normalize_error(reason)
      end

      for reason <- [:timeout, :no_responders, {:jetstream, 503, "x"}, {:exit, :noproc}] do
        assert %DeliveryError{retryable?: true} = Nats.normalize_error(reason)
      end
    end
  end
end
