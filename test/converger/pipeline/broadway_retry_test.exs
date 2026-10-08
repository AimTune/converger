defmodule Converger.Pipeline.BroadwayRetryTest do
  # Mutates global pipeline/adapter config, so it cannot run async.
  use Converger.DataCase, async: false
  use Oban.Testing, repo: Converger.Repo

  alias Converger.{Activities, Deliveries}
  alias Converger.Pipeline
  alias Converger.Pipeline.Broadway.Pipeline, as: BroadwayPipeline
  alias Converger.Pipeline.RetryPolicy
  alias Converger.Workers.ActivityDeliveryWorker

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  setup do
    for key <- [:pipeline, :webhook_req_options, :retry_policy] do
      previous = Application.get_env(:converger, key)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:converger, key, previous),
          else: Application.delete_env(:converger, key)
      end)
    end

    Application.put_env(:converger, :pipeline,
      backend: Converger.Pipeline.Broadway,
      broadway: [producer: :custom, custom: [push_module: Converger.TestBroadwayPush]]
    )

    Application.put_env(:converger, :webhook_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    tenant = tenant_fixture()
    channel = webhook_channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  # Stub the webhook endpoint: fail the first `failures` requests with a 500.
  defp stub_webhook(failures) do
    calls = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) <= failures,
        do: Plug.Conn.send_resp(conn, 500, "down"),
        else: Req.Test.json(conn, %{ok: true})
    end)

    calls
  end

  # Create an activity under the Broadway backend and run the pushed message
  # through the real Broadway processor and delivery batcher callbacks.
  defp create_and_run_broadway(tenant, conversation) do
    {:ok, activity} =
      Activities.create_activity(%{
        type: "message",
        sender: "user-1",
        text: "hello",
        tenant_id: tenant.id,
        conversation_id: conversation.id
      })

    assert_received {:broadway_push, pushed}

    message = %Broadway.Message{data: pushed, acknowledger: Broadway.NoopAcknowledger.init()}
    message = BroadwayPipeline.handle_message(:default, message, %{})
    [result] = BroadwayPipeline.handle_batch(:delivery, [message], nil, %{})

    {activity, result}
  end

  defp drain_retries do
    Oban.drain_queue(queue: :deliveries, with_scheduled: true, with_recursion: true)
  end

  test "transient failures are retried until the delivery is sent", %{
    tenant: tenant,
    channel: channel,
    conversation: conversation
  } do
    calls = stub_webhook(2)

    Oban.Testing.with_testing_mode(:manual, fn ->
      {activity, result} = create_and_run_broadway(tenant, conversation)

      # The first failure is handed off to Oban and the Broadway message acked.
      assert result.status == :ok

      assert_enqueued(
        worker: ActivityDeliveryWorker,
        args: %{activity_id: activity.id, channel_id: channel.id}
      )

      assert %{success: 1, failure: 1} = drain_retries()

      delivery = Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)
      assert delivery.status == "sent"
      assert delivery.attempts == 3
      assert :counters.get(calls, 1) == 3
    end)
  end

  test "permanent failures are dead-lettered after max attempts", %{
    tenant: tenant,
    channel: channel,
    conversation: conversation
  } do
    stub_webhook(:infinity)

    ref =
      :telemetry_test.attach_event_handlers(self(), [[:converger, :deliveries, :dead_lettered]])

    Oban.Testing.with_testing_mode(:manual, fn ->
      {activity, _result} = create_and_run_broadway(tenant, conversation)

      assert %{cancelled: 1} = drain_retries()

      delivery = Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)
      assert delivery.status == "failed"
      assert delivery.attempts == RetryPolicy.max_attempts()
      assert delivery.last_error =~ "500"

      assert [%{id: id}] = Deliveries.list_dead_letters(%{channel_id: channel.id})
      assert id == delivery.id

      assert_received {[:converger, :deliveries, :dead_lettered], ^ref, %{attempts: 5},
                       %{delivery_id: ^id}}
    end)
  end

  test "middleware halts are dead-lettered without a retry", %{tenant: tenant} do
    stub_webhook(0)

    channel =
      webhook_channel_fixture(tenant, %{
        transformations: [%{"type" => "content_filter", "block_patterns" => ["hello"]}]
      })

    conversation = conversation_fixture(tenant, channel)

    Oban.Testing.with_testing_mode(:manual, fn ->
      {activity, result} = create_and_run_broadway(tenant, conversation)

      assert {:failed, _} = result.status
      refute_enqueued(worker: ActivityDeliveryWorker)

      delivery = Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)
      assert delivery.status == "failed"
      assert delivery.attempts == 1
    end)
  end

  describe "RetryPolicy is shared" do
    test "Deliveries and the Oban worker follow the configured policy", %{
      tenant: tenant,
      conversation: conversation,
      channel: channel
    } do
      Application.put_env(:converger, :retry_policy, max_attempts: 2, base_backoff_seconds: 1)

      {:ok, activity} =
        Activities.create_activity(%{
          type: "message",
          sender: "user-1",
          text: "hi",
          tenant_id: tenant.id,
          conversation_id: conversation.id
        })

      delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)
      {:ok, delivery} = Deliveries.mark_attempt_failed(delivery, "boom")
      assert delivery.status == "pending"
      {:ok, delivery} = Deliveries.mark_attempt_failed(delivery, "boom")
      assert delivery.status == "failed"

      assert ActivityDeliveryWorker.backoff(%Oban.Job{attempt: 2}) == RetryPolicy.backoff(2)
      assert RetryPolicy.backoff(2) == 9
    end

    test "retryable?/1 classifies deliver/2 results" do
      assert Pipeline.retryable?({:error, :timeout})
      refute Pipeline.retryable?({:error, {:halted, "blocked"}})
      refute Pipeline.retryable?({:error, {:dead_lettered, :timeout}})
      refute Pipeline.retryable?(:ok)
    end
  end
end
