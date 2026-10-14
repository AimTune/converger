defmodule Converger.Backbone.TransactionalPublishTest do
  @moduledoc """
  The transactional outbox of the backbone (#66): `activity.created` is
  published in the transaction that stores the activity, so the event exists
  exactly when the activity does. Publishing after the commit lost events
  when a node died between the commit and the publish (the benchmark
  matrix's rolling restart and node kill).
  """

  use Converger.DataCase, async: false
  use Oban.Testing, repo: Converger.Repo

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Backbone, Repo}
  alias Converger.Workers.{BackboneEventWorker, BackbonePublishWorker}

  # A node that dies right after the commit: the after-commit work never runs.
  defmodule CrashAfterCommitPipeline do
    @behaviour Converger.Pipeline
    def child_specs, do: []
    alias Converger.Pipeline.Oban, as: ObanPipeline
    def enqueue(activity), do: ObanPipeline.enqueue(activity)
    def after_commit(_activity), do: raise("node died after the commit")
  end

  defp subscribe(name) do
    {:ok, _} = Backbone.subscribe(:activities, fn _event -> :ok end, name: name)
    on_exit(fn -> Backbone.unsubscribe(name) end)
  end

  defp attrs(conversation) do
    %{
      "type" => "message",
      "text" => "hi",
      "sender" => "user-1",
      "tenant_id" => conversation.tenant_id,
      "conversation_id" => conversation.id
    }
  end

  setup do
    tenant = tenant_fixture()
    conversation = conversation_fixture(tenant, channel_fixture(tenant))
    %{conversation: conversation}
  end

  describe "publish_in_transaction/2" do
    test "Native: the subscription's job commits and rolls back with the transaction" do
      subscribe("outbox-native")

      Oban.Testing.with_testing_mode(:manual, fn ->
        Repo.transaction(fn ->
          Backbone.publish_in_transaction(:activities, %{type: "activity.created", data: %{}})
          Repo.rollback(:boom)
        end)

        refute_enqueued(worker: BackboneEventWorker)

        {:ok, event} =
          Repo.transaction(fn ->
            Backbone.publish_in_transaction(:activities, %{type: "activity.created", data: %{}})
          end)

        assert_enqueued(
          worker: BackboneEventWorker,
          args: %{"subscription" => "outbox-native", "event" => %{"id" => event.id}}
        )
      end)
    end

    test "a broker: a publish job is stored with the transaction and keeps the event id" do
      Application.put_env(:converger, :backbone, Converger.Backbone.Nats)
      on_exit(fn -> Application.put_env(:converger, :backbone, Converger.Backbone.Native) end)

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, event} =
          Repo.transaction(fn ->
            Backbone.publish_in_transaction(:activities, %{type: "activity.created", data: %{}})
          end)

        assert_enqueued(
          worker: BackbonePublishWorker,
          args: %{"backbone" => "nats", "event" => %{"id" => event.id}}
        )
      end)
    end

    test "outside a transaction it refuses to run" do
      assert_raise ArgumentError, fn ->
        Backbone.publish_in_transaction(:activities, %{type: "activity.created", data: %{}})
      end
    end
  end

  describe "create_activity/2" do
    test "activity.created is in the activity's transaction", %{conversation: conversation} do
      subscribe("outbox-activities")

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, activity} = Activities.create_activity(attrs(conversation))

        assert [job] = all_enqueued(worker: BackboneEventWorker)
        assert job.args["event"]["type"] == "activity.created"
        assert job.args["event"]["data"]["id"] == activity.id
      end)
    end

    test "the event survives a node that dies right after the commit", %{
      conversation: conversation
    } do
      subscribe("outbox-crash")
      previous = Application.get_env(:converger, :pipeline, [])

      Application.put_env(
        :converger,
        :pipeline,
        Keyword.put(previous, :backend, CrashAfterCommitPipeline)
      )

      on_exit(fn -> Application.put_env(:converger, :pipeline, previous) end)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert_raise RuntimeError, ~r/died after the commit/, fn ->
          Activities.create_activity(attrs(conversation))
        end

        [activity] = Activities.list_activities_since(conversation.id, nil)

        assert [job] =
                 all_enqueued(worker: BackboneEventWorker)
                 |> Enum.filter(&(&1.args["subscription"] == "outbox-crash"))

        assert job.args["event"]["data"]["id"] == activity.id
      end)
    end

    test "no event when the activity is not stored", %{conversation: conversation} do
      subscribe("outbox-rejected")
      {:ok, _} = Converger.Conversations.close_conversation(conversation)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:error, :conversation_closed} = Activities.create_activity(attrs(conversation))

        assert all_enqueued(worker: BackboneEventWorker)
               |> Enum.filter(&(&1.args["event"]["type"] == "activity.created")) == []
      end)
    end
  end
end
