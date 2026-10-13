defmodule Converger.Channels.NatsIntegrationTest do
  @moduledoc """
  The `nats` channel end to end against a real NATS server with JetStream
  (issue #42). Excluded by default; see
  docs/channels/brokers.md#running-the-broker-tests:

      docker run -d --name nats -p 4222:4222 nats:2.10 -js
      NATS_URL=nats://localhost:4222 mix test --only nats
  """

  use ConvergerWeb.ChannelCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Ecto.Query

  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias Converger.{Channels, Repo, RoutingRules}
  alias Converger.Channels.Adapters.Nats
  alias Converger.Channels.Broker.Publishers
  alias Converger.Channels.Consumers
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}
  alias Gnat.Jetstream.API.{Consumer, Stream}

  @moduletag :nats
  @moduletag timeout: 300_000

  setup do
    url = System.get_env("NATS_URL", "nats://localhost:4222")

    webhook = Application.get_env(:converger, :webhook, [])
    Application.put_env(:converger, :webhook, Keyword.put(webhook, :allow_private_targets, true))
    on_exit(fn -> Application.put_env(:converger, :webhook, webhook) end)

    suffix = System.unique_integer([:positive])
    stream = "IT#{suffix}"
    out_stream = "IT#{suffix}OUT"
    subject_in = "it#{suffix}.in"

    # The "external script": a connection of its own. out_stream stores
    # what the channel publishes (one subject per conversation).
    {:ok, conn} = Nats.connect(%{"servers" => url})

    {:ok, _} =
      Stream.create(conn, %Stream{name: out_stream, subjects: ["it#{suffix}.out.>"]})

    on_exit(fn ->
      {:ok, conn} = Nats.connect(%{"servers" => url})
      Stream.delete(conn, stream)
      Stream.delete(conn, out_stream)
      Gnat.stop(conn)
    end)

    tenant = tenant_fixture()

    {:ok, nats} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "nats",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "servers" => url,
          "stream" => stream,
          "subject_in" => subject_in,
          "subject_out" => "it#{suffix}.out.{conversation_id}",
          "declare" => true
        }
      })

    console = channel_fixture(tenant, %{mode: "duplex"})

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "nats to console",
        tenant_id: tenant.id,
        source_channel_id: nats.id,
        target_channel_ids: [console.id]
      })

    on_exit(fn ->
      Consumers.stop_consumer(nats.id)
      Publishers.stop(nats.id)
    end)

    %{
      conn: conn,
      nats: nats,
      console: console,
      stream: stream,
      out_stream: out_stream,
      subject_in: subject_in,
      suffix: suffix
    }
  end

  # A JetStream publish, as an external producer would do it.
  defp publish(conn, subject, payload, headers \\ []) do
    {:ok, %{body: body}} = Gnat.request(conn, subject, payload, headers: headers)
    assert %{"seq" => _} = Jason.decode!(body)
  end

  defp stream_ready?(conn, stream), do: match?({:ok, _}, Stream.info(conn, stream))

  defp consumer_info(conn, stream, durable) do
    {:ok, info} = Consumer.info(conn, stream, durable)
    info
  end

  defp header(hdrs, name) do
    hdrs
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ": ", parts: 2) do
        [^name, value] -> value
        _ -> nil
      end
    end)
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
    handler = "it-nats-#{channel_id}"
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

  test "a message published to subject_in reaches a WS client and the reply is published", %{
    conn: conn,
    nats: nats,
    console: console,
    stream: stream,
    out_stream: out_stream,
    subject_in: subject_in,
    suffix: suffix
  } do
    {:ok, token, _} = ConvergerToken.generate_token(console, scope: "channel", user_id: "agent-7")
    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:channel:#{console.id}")

    {:ok, _} = Consumers.start_consumer(nats)

    # declare: true created the stream (subject_in and its dead-letter subject).
    eventually(fn -> stream_ready?(conn, stream) end)

    publish(
      conn,
      subject_in,
      Jason.encode!(%{"text" => "Hello", "participant" => %{"external_id" => "cust-1"}})
    )

    assert_push "activitySet", %{conversation_id: conversation_id, activities: [frame]}, 30_000
    assert frame.text == "Hello"

    ref =
      push(socket, "postActivity", %{"conversation_id" => conversation_id, "text" => "Hi there"})

    assert_reply ref, :ok, %{id: reply_id}, 30_000

    {:ok, message} =
      eventually(fn ->
        case Stream.get_message(conn, out_stream, %{seq: 1}) do
          {:ok, _} = ok -> ok
          {:error, _} -> nil
        end
      end)

    # Only the reply: the consumed message is not echoed back.
    Process.sleep(500)
    assert {:ok, %{state: %{messages: 1}}} = Stream.info(conn, out_stream)

    assert message.subject == "it#{suffix}.out.#{conversation_id}"

    envelope = Jason.decode!(message.data)
    assert envelope["id"] == reply_id
    assert envelope["text"] == "Hi there"
    assert envelope["conversation_id"] == conversation_id
    assert envelope["channel_id"] == nats.id
    assert envelope["tenant_id"] == nats.tenant_id

    assert header(message.hdrs, "Nats-Msg-Id") == reply_id
    assert header(message.hdrs, "Content-Type") == "application/json"
    assert header(message.hdrs, "X-Converger-Conversation-Id") == conversation_id
  end

  test "a restarted consumer resumes without duplicates; a replay is recognised", %{
    conn: conn,
    nats: nats,
    stream: stream,
    subject_in: subject_in
  } do
    attach_inbound(nats.id)
    durable = Nats.durable_name(nats)
    {:ok, _} = Consumers.start_consumer(nats)
    eventually(fn -> stream_ready?(conn, stream) end)

    publish(conn, subject_in, ~s({"text": "one"}))
    assert_receive {:inbound, :created}, 30_000

    :ok = Consumers.stop_consumer(nats.id)
    publish(conn, subject_in, ~s({"text": "two"}))
    publish(conn, subject_in, ~s({"text": "three"}))

    {:ok, _} = Consumers.start_consumer(nats)
    assert_receive {:inbound, :created}, 30_000
    assert_receive {:inbound, :created}, 30_000
    refute_receive {:inbound, _}, 2_000

    assert nats.id |> inbound_activities() |> Enum.map(& &1.idempotency_key) |> Enum.sort() ==
             ["nats:#{stream}/1", "nats:#{stream}/2", "nats:#{stream}/3"]

    # Everything was acknowledged.
    eventually(fn ->
      info = consumer_info(conn, stream, durable)
      info.num_ack_pending == 0 and info.num_pending == 0
    end)

    # A replay of the whole stream (the durable consumer recreated) brings
    # the same stream sequences again: duplicates, no new activities.
    :ok = Consumers.stop_consumer(nats.id)
    :ok = Consumer.delete(conn, stream, durable)
    {:ok, _} = Consumers.start_consumer(nats)

    for _ <- 1..3, do: assert_receive({:inbound, :duplicate}, 30_000)
    assert length(inbound_activities(nats.id)) == 3
  end

  test "poison messages are published to the dead-letter subject", %{
    conn: conn,
    nats: nats,
    stream: stream,
    subject_in: subject_in
  } do
    {:ok, _} = Consumers.start_consumer(nats)
    eventually(fn -> stream_ready?(conn, stream) end)

    publish(conn, subject_in, "{not json", [{"trace-id", "t-1"}])
    publish(conn, subject_in, ~s({"text": "fine"}))

    {:ok, message} =
      eventually(fn ->
        case Stream.get_message(conn, stream, %{last_by_subj: "#{subject_in}.dlq"}) do
          {:ok, _} = ok -> ok
          {:error, _} -> nil
        end
      end)

    assert message.data == "{not json"
    assert header(message.hdrs, "X-Converger-Error") == "message body is not valid JSON"
    assert header(message.hdrs, "X-Converger-Channel-Id") == nats.id
    assert header(message.hdrs, "X-Converger-Source") == "#{stream}/1"
    assert header(message.hdrs, "trace-id") == "t-1"

    eventually(fn -> inbound_activities(nats.id) end)
    assert [%{text: "fine"}] = inbound_activities(nats.id)
  end

  test "the health probe connects and finds the stream", %{conn: conn, nats: nats, stream: stream} do
    assert {:error, {:stream, ^stream, _}} = Nats.health_probe(nats)

    {:ok, _} = Consumers.start_consumer(nats)
    eventually(fn -> stream_ready?(conn, stream) end)
    assert Nats.health_probe(nats) == :ok
  end
end
