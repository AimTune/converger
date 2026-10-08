defmodule Converger.Pipeline.TransactionalEnqueueTest do
  # Mutates global pipeline config, so it cannot run async.
  use Converger.DataCase, async: false
  use Oban.Testing, repo: Converger.Repo

  alias Converger.Activities
  alias Converger.Activities.Activity
  alias Converger.Pipeline
  alias Converger.Workers.ActivityDeliveryWorker

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  setup do
    previous = Application.get_env(:converger, :pipeline)
    on_exit(fn -> Application.put_env(:converger, :pipeline, previous) end)

    tenant = tenant_fixture()
    channel = webhook_channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    attrs = %{
      type: "message",
      sender: "user-1",
      text: "hello",
      tenant_id: tenant.id,
      conversation_id: conversation.id
    }

    %{channel: channel, conversation: conversation, attrs: attrs}
  end

  defp use_backend(backend) do
    Application.put_env(:converger, :pipeline, backend: backend)
  end

  defp delivery_job_count do
    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == ^inspect(ActivityDeliveryWorker)),
      :count
    )
  end

  describe "Oban backend" do
    setup do
      use_backend(Converger.Pipeline.Oban)
      :ok
    end

    test "enqueues delivery jobs together with the activity", %{attrs: attrs, channel: channel} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %Activity{} = activity} = Activities.create_activity(attrs)

        assert_enqueued(
          worker: ActivityDeliveryWorker,
          args: %{activity_id: activity.id, channel_id: channel.id}
        )

        assert delivery_job_count() == 1
      end)
    end

    test "re-running the pipeline does not duplicate jobs", %{attrs: attrs} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, activity} = Activities.create_activity(attrs)

        assert :ok = Pipeline.process(activity)
        assert :ok = Pipeline.process(activity)

        assert delivery_job_count() == 1
      end)
    end

    test "idempotent re-submission does not duplicate jobs", %{attrs: attrs} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        attrs = Map.put(attrs, :idempotency_key, "key-1")

        {:ok, first} = Activities.create_activity(attrs)
        {:ok, second} = Activities.create_activity(attrs)

        assert first.id == second.id
        assert delivery_job_count() == 1
      end)
    end
  end

  describe "failure inside the pipeline" do
    setup do
      use_backend(Converger.FailingPipeline)
      :ok
    end

    test "a raise rolls back both the activity and its already-inserted jobs", %{
      attrs: attrs,
      conversation: conversation
    } do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert_raise RuntimeError, ~r/pipeline exploded/, fn ->
          Activities.create_activity(attrs)
        end

        assert Activities.list_activities_for_conversation(conversation.id) == []
        assert delivery_job_count() == 0
      end)
    end

    test "an error return rolls back and is reported to the caller", %{
      attrs: attrs,
      conversation: conversation
    } do
      Process.put(:failing_pipeline_mode, :error)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:error, :delivery_enqueue_failed} = Activities.create_activity(attrs)

        assert Activities.list_activities_for_conversation(conversation.id) == []
        assert delivery_job_count() == 0
      end)
    end
  end

  describe "Broadway memory producer guard" do
    test "refuses to start in prod unless explicitly allowed" do
      assert_raise ArgumentError, ~r/not durable/, fn ->
        Pipeline.Broadway.ensure_memory_producer_allowed!([], :prod)
      end

      assert :ok =
               Pipeline.Broadway.ensure_memory_producer_allowed!(
                 [allow_memory_producer_in_prod: true],
                 :prod
               )

      assert :ok = Pipeline.Broadway.ensure_memory_producer_allowed!([], :dev)
    end
  end
end
