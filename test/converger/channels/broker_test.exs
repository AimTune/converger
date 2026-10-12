defmodule Converger.Channels.BrokerTest do
  # Inbound handling of broker channel messages (idempotency, poison
  # messages, retries, dead-lettering), without a broker: the test_broker
  # adapter (test/support/test_broker_adapter.ex).
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Channels, Conversations, Deliveries}
  alias Converger.Channels.Broker
  alias Converger.TestBrokerAdapter

  setup do
    put_env(:adapters, [TestBrokerAdapter])
    put_env(:test_broker_pid, self())
    put_env(:test_broker_dlq_failures, 0)

    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "test_broker",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{"topic_in" => "in"}
      })

    %{tenant: tenant, channel: channel}
  end

  defp put_env(key, value) do
    previous = Application.get_env(:converger, key)
    Application.put_env(:converger, key, value)
    on_exit(fn -> Application.put_env(:converger, key, previous) end)
  end

  defp info(payload, id \\ "in/0/1") when is_map(payload) or is_binary(payload) do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)
    %{payload: body, message_id: id, source: id, key: nil, headers: []}
  end

  defp handle(channel, info, opts \\ []) do
    test = self()
    Broker.handle(channel, TestBrokerAdapter, info, [sleep: &send(test, {:slept, &1})] ++ opts)
  end

  describe "accepted messages" do
    test "a message becomes an activity keyed by the broker message id", %{channel: channel} do
      assert {:ok, :created, activity} =
               handle(channel, info(%{"text" => "hello", "sender" => "crm"}, "in/0/7"))

      assert activity.text == "hello"
      assert activity.sender == "crm"
      assert activity.idempotency_key == "test_broker:in/0/7"

      assert activity.metadata["converger_broker"] == %{
               "channel_id" => channel.id,
               "message_id" => "in/0/7",
               "source" => "in/0/7"
             }

      assert Conversations.get_conversation!(activity.conversation_id).channel_id == channel.id
    end

    test "a redelivered message is a duplicate, not a second activity", %{channel: channel} do
      message = info(%{"text" => "once"}, "in/3/42")

      assert {:ok, :created, first} = handle(channel, message)
      assert {:ok, :duplicate, again} = handle(channel, message)
      assert again.id == first.id

      assert Repo.aggregate(
               from(a in Activities.Activity, where: a.idempotency_key == "test_broker:in/3/42"),
               :count
             ) == 1
    end

    test "an envelope idempotency_key wins over the broker message id", %{channel: channel} do
      assert {:ok, :created, first} =
               handle(channel, info(%{"text" => "x", "idempotency_key" => "crm-1"}, "in/0/1"))

      assert first.idempotency_key == "crm-1"

      # The producer retried: same key, new offset.
      assert {:ok, :duplicate, again} =
               handle(channel, info(%{"text" => "x", "idempotency_key" => "crm-1"}, "in/0/2"))

      assert again.id == first.id
    end

    test "without any id every delivery is accepted (at-least-once)", %{channel: channel} do
      assert {:ok, :created, a} = handle(channel, info(%{"text" => "x"}, nil))
      assert {:ok, :created, b} = handle(channel, info(%{"text" => "x"}, nil))
      assert a.id != b.id
      assert a.idempotency_key == nil
    end

    test "participant messages share the participant's open conversation", %{channel: channel} do
      payload = %{"text" => "1", "participant" => %{"external_id" => "cust-9"}}
      assert {:ok, :created, a} = handle(channel, info(payload, "in/0/1"))
      assert {:ok, :created, b} = handle(channel, info(%{payload | "text" => "2"}, "in/0/2"))
      assert a.conversation_id == b.conversation_id
      assert a.sender == "cust-9"
    end

    test "conversation_id writes into an existing conversation of the tenant", %{
      tenant: tenant,
      channel: channel
    } do
      console = channel_fixture(tenant)
      conversation = conversation_fixture(tenant, console)

      assert {:ok, :created, activity} =
               handle(
                 channel,
                 info(%{"text" => "bot reply", "conversation_id" => conversation.id})
               )

      assert activity.conversation_id == conversation.id
    end

    test "an outbound envelope fed back is accepted as a new inbound message", %{
      tenant: tenant,
      channel: channel
    } do
      console = channel_fixture(tenant)
      conversation = conversation_fixture(tenant, console)

      {:ok, source} =
        Activities.create_activity(%{
          "tenant_id" => tenant.id,
          "conversation_id" => conversation.id,
          "text" => "copied",
          "sender" => "agent"
        })

      payload = Broker.Envelope.encode(source, channel)

      assert {:ok, :created, activity} = handle(channel, info(payload, "in/0/99"))
      assert activity.id != source.id
      assert activity.conversation_id == conversation.id
      assert activity.text == "copied"
    end
  end

  describe "echo suppression" do
    test "a consumed message is not delivered back to its broker channel", %{channel: channel} do
      assert {:ok, :created, activity} = handle(channel, info(%{"text" => "hi"}))

      refute_received {:test_broker_delivered, _, _}

      delivery = Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)
      assert delivery.status == "sent"
    end

    test "a reply in the conversation is delivered to the broker channel", %{channel: channel} do
      assert {:ok, :created, activity} = handle(channel, info(%{"text" => "hi"}))

      {:ok, reply} =
        Activities.create_activity(%{
          "tenant_id" => channel.tenant_id,
          "conversation_id" => activity.conversation_id,
          "text" => "reply",
          "sender" => "agent"
        })

      channel_id = channel.id
      reply_id = reply.id
      assert_received {:test_broker_delivered, ^channel_id, ^reply_id}
    end
  end

  describe "poison messages" do
    for {name, payload, reason} <- [
          {"invalid JSON", "{not json", "message body is not valid JSON"},
          {"a JSON array", "[1, 2]", "message body is not a JSON object"},
          {"an empty message", ~s({"text": "  "}), "message has neither text nor attachments"},
          {"a bad conversation_id", ~s({"text": "x", "conversation_id": "nope"}),
           "conversation_id is not a UUID"}
        ] do
      test "#{name} is dead-lettered without retries", %{channel: channel} do
        channel_id = channel.id

        assert {:dead_lettered, :poison, unquote(reason)} =
                 handle(channel, info(unquote(payload), "in/0/5"))

        assert_received {:test_broker_dead_letter, ^channel_id, %{source: "in/0/5"},
                         unquote(reason)}

        refute_received {:slept, _}
      end
    end

    test "a message for another tenant or channel is dead-lettered", %{channel: channel} do
      assert {:dead_lettered, :poison, "tenant_id does not match the consuming channel"} =
               handle(channel, info(%{"text" => "x", "tenant_id" => Ecto.UUID.generate()}))

      assert {:dead_lettered, :poison, "channel_id does not match the consuming channel"} =
               handle(channel, info(%{"text" => "x", "channel_id" => Ecto.UUID.generate()}))
    end

    test "an unknown conversation or another tenant's is dead-lettered", %{channel: channel} do
      other_tenant = tenant_fixture()
      foreign = conversation_fixture(other_tenant, channel_fixture(other_tenant))

      for id <- [Ecto.UUID.generate(), foreign.id] do
        assert {:dead_lettered, :poison, "conversation not found"} =
                 handle(channel, info(%{"text" => "x", "conversation_id" => id}))
      end
    end

    test "a closed conversation is dead-lettered", %{tenant: tenant, channel: channel} do
      conversation = conversation_fixture(tenant, channel)
      {:ok, _} = Conversations.close_conversation(conversation)

      assert {:dead_lettered, :poison, "conversation is closed"} =
               handle(channel, info(%{"text" => "x", "conversation_id" => conversation.id}))
    end

    test "an activity the schema rejects is dead-lettered", %{channel: channel} do
      assert {:dead_lettered, :poison, "rejected: " <> _} =
               handle(channel, info(%{"type" => "bogus", "text" => "x"}))
    end
  end

  describe "transient failures" do
    test "are retried with backoff, then dead-lettered", %{channel: channel} do
      # A channel id that is not a UUID makes the duplicate lookup raise.
      broken = %{channel | id: "not-a-uuid"}

      assert {:dead_lettered, :retries_exhausted, reason} =
               handle(broken, info(%{"text" => "x"}),
                 max_attempts: 3,
                 backoff_ms: 10,
                 max_backoff_ms: 1_000
               )

      assert reason =~ "failed after 3 attempts"
      assert_received {:slept, 10}
      assert_received {:slept, 20}
      refute_received {:slept, _}
      assert_received {:test_broker_dead_letter, "not-a-uuid", _, ^reason}
    end
  end

  describe "dead-letter writes" do
    test "are retried until they succeed", %{channel: channel} do
      Application.put_env(:converger, :test_broker_dlq_failures, 2)

      assert {:dead_lettered, :poison, _} =
               handle(channel, info("{oops"), backoff_ms: 7, dead_letter_max_backoff_ms: 10)

      assert_received {:slept, 7}
      assert_received {:slept, 10}
      assert_received {:test_broker_dead_letter, _, _, "message body is not valid JSON"}
    end
  end

  test "backoff doubles up to the maximum" do
    opts = [base: 500, max: 30_000]
    assert Broker.backoff(opts, :base, :max, 1) == 500
    assert Broker.backoff(opts, :base, :max, 2) == 1_000
    assert Broker.backoff(opts, :base, :max, 7) == 30_000
    assert Broker.backoff(opts, :base, :max, 200) == 30_000
  end

  test "contains_any?/2 finds nested reason codes" do
    assert Broker.contains_any?({:error, [{{"k", 9092}, {:sasl_authentication_failed, "x"}}]}, [
             :sasl_authentication_failed
           ])

    assert Broker.contains_any?(%{reason: :target_blocked}, [:target_blocked])
    refute Broker.contains_any?({:error, :timeout}, [:target_blocked])
  end
end
