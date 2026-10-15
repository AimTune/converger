defmodule Converger.Channels.RabbitMQIntegrationTest do
  @moduledoc """
  The `rabbitmq` channel end to end against a real RabbitMQ broker (issue
  #42). Excluded by default; see docs/channels/brokers.md#running-the-broker-tests:

      docker run -d --name rabbitmq -p 5672:5672 rabbitmq:3.13-management
      RABBITMQ_URL=amqp://localhost:5672 mix test --only rabbitmq
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
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  @moduletag :rabbitmq
  @moduletag timeout: 300_000

  setup do
    url = System.get_env("RABBITMQ_URL", "amqp://localhost:5672")
    username = System.get_env("RABBITMQ_USERNAME", "guest")
    password = System.get_env("RABBITMQ_PASSWORD", "guest")

    webhook = Application.get_env(:converger, :webhook, [])
    Application.put_env(:converger, :webhook, Keyword.put(webhook, :allow_private_targets, true))
    on_exit(fn -> Application.put_env(:converger, :webhook, webhook) end)

    suffix = System.unique_integer([:positive])
    queue_in = "it#{suffix}.in"
    queue_out = "it#{suffix}.out"

    # The "external script": a connection of its own. queue_out receives
    # what the channel publishes to the default exchange with its name.
    {:ok, conn} =
      AMQP.Connection.open(
        Keyword.merge(
          Converger.Channels.Adapters.RabbitMQ.connection_options(%{"url" => url})
          |> elem(1),
          username: username,
          password: password
        )
      )

    {:ok, chan} = AMQP.Channel.open(conn)
    {:ok, _} = AMQP.Queue.declare(chan, queue_out, durable: true)

    on_exit(fn ->
      for queue <- [queue_in, queue_out, "#{queue_in}.dlq"] do
        AMQP.Queue.delete(chan, queue)
      end

      AMQP.Connection.close(conn)
    end)

    tenant = tenant_fixture()

    {:ok, rabbit} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "rabbitmq",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "url" => url,
          "username" => username,
          "password" => password,
          "queue" => queue_in,
          "exchange" => "",
          "routing_key" => queue_out,
          "declare" => true
        }
      })

    console = channel_fixture(tenant, %{mode: "duplex"})

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "rabbitmq to console",
        tenant_id: tenant.id,
        source_channel_id: rabbit.id,
        target_channel_ids: [console.id]
      })

    on_exit(fn ->
      Consumers.stop_consumer(rabbit.id)
      Publishers.stop(rabbit.id)
    end)

    %{
      conn: conn,
      chan: chan,
      rabbit: rabbit,
      console: console,
      queue_in: queue_in,
      queue_out: queue_out
    }
  end

  # A passive declare of a missing queue closes the AMQP channel: use a
  # throwaway one.
  defp queue_exists?(conn, queue) do
    {:ok, chan} = AMQP.Channel.open(conn)

    try do
      match?({:ok, _}, AMQP.Queue.declare(chan, queue, passive: true))
    catch
      :exit, _ -> false
    after
      if Process.alive?(chan.pid), do: AMQP.Channel.close(chan)
    end
  end

  defp publish(chan, queue, payload, opts) do
    :ok = AMQP.Basic.publish(chan, "", queue, payload, [persistent: true] ++ opts)
  end

  defp get(chan, queue) do
    case AMQP.Basic.get(chan, queue, no_ack: true) do
      {:ok, payload, meta} -> {payload, meta}
      {:empty, _} -> nil
    end
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
    handler = "it-rabbitmq-#{channel_id}"
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

  test "a message published to the queue reaches a WS client and the reply is published", %{
    conn: conn,
    chan: chan,
    rabbit: rabbit,
    console: console,
    queue_in: queue_in,
    queue_out: queue_out
  } do
    {:ok, token, _} = ConvergerToken.generate_token(console, scope: "channel", user_id: "agent-7")
    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:channel:#{console.id}")

    {:ok, _} = Consumers.start_consumer(rabbit)

    # declare: true created the queue (and its dead-letter queue).
    eventually(fn -> queue_exists?(conn, queue_in) end)

    publish(
      chan,
      queue_in,
      Jason.encode!(%{"text" => "Hello", "participant" => %{"external_id" => "cust-1"}}),
      message_id: "ext-1"
    )

    assert_push "activitySet", %{conversation_id: conversation_id, activities: [frame]}, 30_000
    assert frame.text == "Hello"

    ref =
      push(socket, "postActivity", %{"conversation_id" => conversation_id, "text" => "Hi there"})

    assert_reply ref, :ok, %{id: reply_id}, 30_000

    {payload, meta} = eventually(fn -> get(chan, queue_out) end)
    # Only the reply: the consumed message is not echoed back.
    Process.sleep(500)
    assert get(chan, queue_out) == nil

    envelope = Jason.decode!(payload)
    assert envelope["id"] == reply_id
    assert envelope["text"] == "Hi there"
    assert envelope["conversation_id"] == conversation_id
    assert envelope["channel_id"] == rabbit.id
    assert envelope["tenant_id"] == rabbit.tenant_id

    assert meta.message_id == reply_id
    assert meta.content_type == "application/json"
    assert meta.persistent == true
    headers = Map.new(meta.headers, fn {name, _type, value} -> {name, value} end)
    assert headers["x-converger-conversation-id"] == conversation_id
  end

  test "a restarted consumer resumes without duplicates; redeliveries are recognised", %{
    conn: conn,
    chan: chan,
    rabbit: rabbit,
    queue_in: queue_in
  } do
    attach_inbound(rabbit.id)
    {:ok, _} = Consumers.start_consumer(rabbit)
    eventually(fn -> queue_exists?(conn, queue_in) end)

    publish(chan, queue_in, ~s({"text": "one"}), message_id: "m-1")
    assert_receive {:inbound, :created}, 30_000

    :ok = Consumers.stop_consumer(rabbit.id)
    publish(chan, queue_in, ~s({"text": "two"}), message_id: "m-2")
    publish(chan, queue_in, ~s({"text": "three"}), message_id: "m-3")

    {:ok, _} = Consumers.start_consumer(rabbit)
    assert_receive {:inbound, :created}, 30_000
    assert_receive {:inbound, :created}, 30_000
    refute_receive {:inbound, _}, 2_000

    # The broker redelivers a message (e.g. its ack was lost): same message_id.
    publish(chan, queue_in, ~s({"text": "one"}), message_id: "m-1")
    assert_receive {:inbound, :duplicate}, 30_000

    assert rabbit.id |> inbound_activities() |> Enum.map(& &1.idempotency_key) |> Enum.sort() ==
             ~w(rabbitmq:m-1 rabbitmq:m-2 rabbitmq:m-3)

    # Everything was acknowledged.
    {:ok, %{message_count: 0}} = AMQP.Queue.declare(chan, queue_in, passive: true)
  end

  test "poison messages are published to the dead-letter queue", %{
    conn: conn,
    chan: chan,
    rabbit: rabbit,
    queue_in: queue_in
  } do
    {:ok, _} = Consumers.start_consumer(rabbit)
    eventually(fn -> queue_exists?(conn, queue_in) end)

    publish(chan, queue_in, "{not json",
      message_id: "bad-1",
      headers: [{"trace-id", :longstr, "t-1"}]
    )

    publish(chan, queue_in, ~s({"text": "fine"}), message_id: "ok-1")

    {payload, meta} = eventually(fn -> get(chan, "#{queue_in}.dlq") end)
    assert payload == "{not json"
    assert meta.message_id == "bad-1"
    headers = Map.new(meta.headers, fn {name, _type, value} -> {name, value} end)
    assert headers["x-converger-error"] == "message body is not valid JSON"
    assert headers["x-converger-channel-id"] == rabbit.id
    assert headers["x-converger-source"] == "#{queue_in}/bad-1"
    assert headers["trace-id"] == "t-1"

    eventually(fn -> inbound_activities(rabbit.id) end)
    assert [%{text: "fine"}] = inbound_activities(rabbit.id)
  end
end
