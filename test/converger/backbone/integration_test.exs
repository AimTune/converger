defmodule Converger.Backbone.IntegrationTest do
  @moduledoc """
  End to end over the configured backbone (issue #66): REST activities,
  delivery status changes and conversation lifecycle events reach the
  platform event webhooks through the backbone, exactly once, and the
  WebSocket fan-out keeps working.

  Runs in the default suite against the Native backbone. CI runs it again
  with the Kafka backbone (the `backbone` matrix job):

      BACKBONE=kafka BACKBONE_KAFKA_BROKERS=localhost:9092 \\
        mix test --only backbone_integration

  On a broker backbone the consumers run in their own processes, so the
  database is used outside the SQL sandbox (rows are left behind, as in the
  broker suites).
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest
  import Ecto.Query

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.{Backbone, Conversations, Deliveries, Repo, Webhooks}
  alias Converger.Pipeline.RetryPolicy
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint ConvergerWeb.Endpoint

  @moduletag :backbone_integration
  @moduletag timeout: 300_000

  @url "https://hooks.example.com/backbone-it"

  # On a broker backbone the database stays out of the sandbox for the whole
  # module: switching modes while a consumer is in a transaction breaks it.
  setup_all do
    if Backbone.impl() != Converger.Backbone.Native do
      Sandbox.mode(Repo, :auto)
      on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    end

    :ok
  end

  setup do
    if Backbone.impl() == Converger.Backbone.Native,
      do: Converger.DataCase.setup_sandbox(%{async: false})

    previous = Application.get_env(:converger, :platform_webhook_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :platform_webhook_req_options, previous),
        else: Application.delete_env(:converger, :platform_webhook_req_options)
    end)

    Application.put_env(:converger, :platform_webhook_req_options, plug: {Req.Test, __MODULE__})
    # Broker consumers deliver webhooks from their own processes.
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:webhook, Map.new(conn.req_headers), Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    %{tenant: tenant_fixture()}
  end

  defp subscribe_webhook(tenant, events) do
    {:ok, subscription} =
      Webhooks.create_subscription(tenant.id, %{"url" => @url, "events" => events})

    subscription
  end

  # Webhook POSTs received for `type`, by event id, until `count` arrived.
  defp await_webhooks(type, count, timeout \\ 120_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_webhooks(type, count, %{}, deadline)
  end

  defp collect_webhooks(_type, count, seen, _deadline) when map_size(seen) >= count, do: seen

  defp collect_webhooks(type, count, seen, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:webhook, headers, %{"type" => ^type, "id" => id} = body} ->
        assert headers["x-converger-event-id"] == id
        assert headers["x-converger-signature"] =~ ~r/^t=\d+,v1=[0-9a-f]{64}$/
        collect_webhooks(type, count, Map.update(seen, id, [body], &[body | &1]), deadline)

      {:webhook, _headers, _other} ->
        collect_webhooks(type, count, seen, deadline)
    after
      remaining -> flunk("#{map_size(seen)} of #{count} #{type} webhooks arrived")
    end
  end

  defp await_rows(subscription, count, tries \\ 100) do
    rows = webhook_event_rows(subscription)

    if length(rows) < count and tries > 0 do
      Process.sleep(100)
      await_rows(subscription, count, tries - 1)
    else
      rows
    end
  end

  defp webhook_event_rows(subscription) do
    Repo.all(
      from(e in Webhooks.Event,
        where: e.subscription_id == ^subscription.id,
        select: {e.event_id, e.type}
      )
    )
  end

  test "REST activities reach WebSocket subscribers and the activity.created webhook, once each",
       %{tenant: tenant} do
    subscription = subscribe_webhook(tenant, ["activity.created"])
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    # The real-time fan-out stays on Phoenix.PubSub on every backbone.
    ConvergerWeb.Endpoint.subscribe("conversation:#{conversation.id}")

    ids =
      for i <- 1..5 do
        build_conn()
        |> put_req_header("x-api-key", tenant.api_key)
        |> post("/api/v1/conversations/#{conversation.id}/activities", %{
          "type" => "message",
          "sender" => "user-1",
          "text" => "backbone #{i}"
        })
        |> json_response(201)
        |> get_in(["data", "id"])
      end

    for id <- ids do
      assert_receive %Phoenix.Socket.Broadcast{event: "new_activity", payload: %{id: ^id}}, 5_000
    end

    received = await_webhooks("activity.created", 5)

    assert received |> Map.values() |> Enum.map(&hd(&1)["data"]["id"]) |> Enum.sort() ==
             Enum.sort(ids)

    # Exactly once: one webhook event row per backbone event, no duplicates.
    # (The test runs Oban jobs inline, inside the transaction that writes the
    # rows: the POSTs can arrive before the rows commit.)
    rows = await_rows(subscription, 5)
    assert length(rows) == 5
    assert rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 5
    refute_receive {:webhook, _, %{"type" => "activity.created"}}, 1_000
  end

  test "a dead-lettered delivery is published as delivery.failed", %{tenant: tenant} do
    subscribe_webhook(tenant, ["delivery.failed"])
    channel = webhook_channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel_fixture(tenant))
    activity = activity_fixture(tenant, conversation)
    delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)

    {:ok, _dead} =
      Deliveries.mark_attempt_failed(delivery, "provider exploded", %RetryPolicy{max_attempts: 1})

    [body] = "delivery.failed" |> await_webhooks(1) |> Map.values() |> hd()
    assert body["data"]["activity_id"] == activity.id
    assert body["data"]["conversation_id"] == conversation.id
    assert body["data"]["last_error"] == "provider exploded"
  end

  test "conversation lifecycle events go through the events topic, keyed by conversation",
       %{tenant: tenant} do
    subscribe_webhook(tenant, ["conversation.closed"])
    test_pid = self()
    tenant_id = tenant.id

    {:ok, observer} =
      Backbone.subscribe(:events, fn event -> send(test_pid, {:backbone, event}) end,
        name: "it-#{System.unique_integer([:positive])}",
        filter: &(&1.tenant_id == tenant_id)
      )

    on_exit(fn -> Backbone.unsubscribe(observer) end)

    conversation = conversation_fixture(tenant, channel_fixture(tenant))
    {:ok, _closed} = Conversations.close_conversation(conversation)

    [body] = "conversation.closed" |> await_webhooks(1) |> Map.values() |> hd()
    assert body["data"]["conversation_id"] == conversation.id

    assert_receive {:backbone, %{type: "conversation.closed"} = event}, 120_000
    assert event.topic == :events
    assert event.key == conversation.id
    assert event.id == body["id"]
  end
end
