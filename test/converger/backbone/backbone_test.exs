defmodule Converger.BackboneTest do
  # Mutates the global backbone config and registry.
  use Converger.DataCase, async: false
  use Oban.Testing, repo: Converger.Repo

  import ExUnit.CaptureLog

  alias Converger.{Backbone, Retention}
  alias Converger.Backbone.{Dispatch, Event, Subscription}
  alias Converger.Workers.{BackboneEventWorker, BackbonePublishWorker}

  defmodule DownBackbone do
    @moduledoc false
    @behaviour Converger.Backbone

    @impl true
    def guarantee, do: :at_least_once
    @impl true
    def child_specs, do: []
    @impl true
    def publish(_topic, event) do
      send(Process.get(:backbone_test_pid, self()), {:down_publish, event.id})
      {:error, :broker_down}
    end

    @impl true
    def subscribe(subscription), do: {:ok, subscription}
    @impl true
    def unsubscribe(_subscription), do: :ok
  end

  defmodule RecordingHandler do
    @moduledoc false
    @behaviour Converger.Backbone.Handler

    @impl true
    def accept?(event), do: event.data["wanted"] != false

    @impl true
    def handle_event(event) do
      send(:persistent_term.get({__MODULE__, :pid}), {:handled, event.id})
      :ok
    end
  end

  setup do
    previous = Application.get_env(:converger, Converger.Backbone, [])
    on_exit(fn -> Application.put_env(:converger, Converger.Backbone, previous) end)
    :persistent_term.put({RecordingHandler, :pid}, self())
    Converger.Backbone.Registry.mark_up(DownBackbone)
    :ok
  end

  defp subscribe(name, topics, handler, opts \\ []) do
    {:ok, subscription} = Backbone.subscribe(topics, handler, Keyword.put(opts, :name, name))
    on_exit(fn -> Backbone.unsubscribe(name) end)
    subscription
  end

  describe "topics and events" do
    test "platform event types map to topics" do
      assert Backbone.topic_for_type("activity.created") == :activities
      assert Backbone.topic_for_type("delivery.failed") == :deliveries
      assert Backbone.topic_for_type("conversation.closed") == :events
      assert Backbone.topic_for_type("participant.opted_out") == :events
      assert Backbone.topic_name(:deliveries) == "converger.deliveries"
    end

    test "an event survives the wire format unchanged" do
      event =
        Event.new(:activities, %{
          type: "activity.created",
          tenant_id: Ecto.UUID.generate(),
          data: %{conversation_id: "c-1", text: "hi", at: ~U[2026-10-15 12:00:00Z]}
        })

      assert event.key == "c-1"

      assert event.data == %{
               "conversation_id" => "c-1",
               "text" => "hi",
               "at" => "2026-10-15T12:00:00Z"
             }

      assert {:ok, ^event} = event |> Event.encode() |> Event.decode()
      assert {"x-converger-event-id", event.id} in Event.headers(event)
    end

    test "malformed events are rejected" do
      assert {:error, :invalid_json} = Event.decode("{")
      assert {:error, :invalid_event} = Event.decode(~s({"hello": 1}))

      assert {:error, :unknown_topic} =
               Event.from_map(%{"id" => Ecto.UUID.generate(), "topic" => "nope", "type" => "x"})
    end

    test "subscriptions are validated" do
      handler = fn _ -> :ok end
      assert {:error, _} = Subscription.new(:activities, handler, name: "Bad Name")
      assert {:error, _} = Subscription.new(:nope, handler, name: "ok")
      assert {:error, _} = Subscription.new(:activities, handler, name: "ok", mode: :fanout)
      assert {:error, _} = Subscription.new(:activities, :not_a_handler, name: "ok")
      assert {:ok, %{dedup: true}} = Subscription.new(:activities, handler, name: "ok")

      assert {:ok, %{dedup: false}} =
               Subscription.new(:activities, handler, name: "ok", mode: :broadcast)
    end
  end

  describe "Native backbone" do
    test "a shared subscription gets a job per wanted event, and handles it once" do
      subscribe("unit-native", :events, RecordingHandler)

      event = Event.new(:events, %{type: "conversation.closed", data: %{"wanted" => true}})
      skipped = Event.new(:events, %{type: "conversation.closed", data: %{"wanted" => false}})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = Backbone.publish(:events, event)
        assert :ok = Backbone.publish(:events, skipped)
      end)

      # accept?/1 ran at publish time: no job for the unwanted event.
      assert [%{args: %{"subscription" => "unit-native"}}] =
               all_enqueued(worker: BackboneEventWorker)
               |> Enum.filter(&(&1.args["subscription"] == "unit-native"))

      assert %{success: 1} = Oban.drain_queue(queue: :backbone)
      assert_received {:handled, id} when id == event.id
      assert Dispatch.handled?("unit-native", event.id)

      # The same event again (a rescued job): skipped by its receipt.
      assert :ok =
               perform_job(BackboneEventWorker, %{
                 "subscription" => "unit-native",
                 "event" => Event.to_map(event)
               })

      refute_received {:handled, _}
    end

    test "a broadcast subscription receives events over PubSub" do
      test_pid = self()

      subscribe(
        "unit-bcast",
        :activities,
        fn event ->
          send(test_pid, {:bcast, event.id})
          :ok
        end,
        mode: :broadcast
      )

      event = Event.new(:activities, %{type: "activity.created", data: %{}})
      assert :ok = Backbone.publish(:activities, event)
      assert_receive {:bcast, id} when id == event.id
    end

    test "a job for an unknown subscription fails (retried), an invalid event is cancelled" do
      event = Event.new(:events, %{type: "conversation.closed", data: %{}})

      assert {:error, {:unknown_subscription, "missing"}} =
               perform_job(BackboneEventWorker, %{
                 "subscription" => "missing",
                 "event" => Event.to_map(event)
               })

      subscribe("unit-invalid", :events, RecordingHandler)

      assert {:cancel, {:invalid_event, _}} =
               perform_job(BackboneEventWorker, %{
                 "subscription" => "unit-invalid",
                 "event" => %{"id" => "x", "topic" => "nope", "type" => "x"}
               })
    end
  end

  describe "Dispatch" do
    test "a failing handler rolls back its receipt and is retried" do
      {:ok, subscription} =
        Subscription.new(:events, fn _ -> {:error, :boom} end, name: "unit-fail")

      event = Event.new(:events, %{type: "conversation.closed", data: %{}})
      assert {:error, :boom} = Dispatch.handle(subscription, event)
      refute Dispatch.handled?("unit-fail", event.id)
    end

    test "a raising filter lets the handler decide instead of dropping the event" do
      {:ok, subscription} =
        Subscription.new(:events, fn _ -> :ok end,
          name: "unit-filter",
          filter: fn _ -> raise "bad filter" end
        )

      event = Event.new(:events, %{type: "conversation.closed", data: %{}})

      capture_log(fn ->
        assert {:ok, :handled} = Dispatch.handle(subscription, event)
      end)
    end

    test "consume/2 parks an event its handler keeps failing on" do
      Application.put_env(
        :converger,
        Converger.Backbone,
        Keyword.merge(Application.get_env(:converger, Converger.Backbone, []),
          inline_attempts: 2,
          inline_backoff_ms: 1
        )
      )

      {:ok, subscription} =
        Subscription.new(:events, fn _ -> {:error, :down} end, name: "unit-park")

      event = Event.new(:events, %{type: "conversation.closed", data: %{}})

      Oban.Testing.with_testing_mode(:manual, fn ->
        capture_log(fn -> assert :parked = Dispatch.consume(subscription, event) end)
      end)

      assert_enqueued(
        worker: BackboneEventWorker,
        args: %{"subscription" => "unit-park", "event" => Event.to_map(event)}
      )
    end
  end

  describe "publishing" do
    test "an event a broker refuses is parked in Postgres and published later" do
      Process.put(:backbone_test_pid, self())

      Application.put_env(:converger, :backbone, DownBackbone)
      on_exit(fn -> Application.put_env(:converger, :backbone, Converger.Backbone.Native) end)

      event = Event.new(:events, %{type: "conversation.closed", data: %{}})

      Oban.Testing.with_testing_mode(:manual, fn ->
        capture_log(fn -> assert :ok = Backbone.publish(:events, event) end)
      end)

      assert_received {:down_publish, id} when id == event.id
      [job] = all_enqueued(worker: BackbonePublishWorker)
      assert job.args["event"]["id"] == event.id

      # The parked publish worker only knows the named backbones.
      assert {:cancel, {:unknown_backbone, nil}} =
               perform_job(BackbonePublishWorker, %{job.args | "backbone" => nil})

      assert :ok =
               perform_job(BackbonePublishWorker, %{job.args | "backbone" => "native"})
    end

    test "after a failed publish, publishes to that broker are parked at once for a while" do
      Process.put(:backbone_test_pid, self())
      Application.put_env(:converger, :backbone, DownBackbone)
      on_exit(fn -> Application.put_env(:converger, :backbone, Converger.Backbone.Native) end)

      first = Event.new(:events, %{type: "conversation.closed", data: %{}})
      second = Event.new(:events, %{type: "conversation.closed", data: %{}})

      Oban.Testing.with_testing_mode(:manual, fn ->
        capture_log(fn ->
          assert :ok = Backbone.publish(:events, first)
          assert :ok = Backbone.publish(:events, second)
        end)
      end)

      assert_received {:down_publish, id} when id == first.id
      refute_received {:down_publish, _}
      assert length(all_enqueued(worker: BackbonePublishWorker)) == 2
    end

    test "mirrors receive every event too (dual publish)" do
      Process.put(:backbone_test_pid, self())

      Application.put_env(
        :converger,
        Converger.Backbone,
        Keyword.put(Application.get_env(:converger, Converger.Backbone, []), :mirror, [
          DownBackbone
        ])
      )

      event = Event.new(:events, %{type: "conversation.closed", data: %{}})

      Oban.Testing.with_testing_mode(:manual, fn ->
        capture_log(fn -> assert :ok = Backbone.publish(:events, event) end)
      end)

      assert_received {:down_publish, id} when id == event.id
      assert Backbone.mirrors() == [DownBackbone]
    end

    test "publishes are measured" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:converger, :backbone, :publish, :stop]])

      event = Event.new(:events, %{type: "conversation.closed", data: %{}})
      assert :ok = Backbone.publish(:events, event)

      assert_received {[:converger, :backbone, :publish, :stop], ^ref, %{duration: _},
                       %{backbone: "native", topic: :events, result: :ok}}
    end
  end

  test "receipts are pruned after backbone_receipt_days" do
    now = DateTime.utc_now()

    Repo.insert_all("backbone_receipts", [
      %{
        subscription: "old",
        event_id: Ecto.UUID.bingenerate(),
        inserted_at: DateTime.add(now, -10, :day)
      },
      %{subscription: "new", event_id: Ecto.UUID.bingenerate(), inserted_at: now}
    ])

    assert %{backbone_receipts: pruned} = Retention.prune(backbone_receipt_days: 7)
    assert pruned >= 1

    assert Repo.all(
             from(r in "backbone_receipts",
               where: r.subscription in ["old", "new"],
               select: r.subscription
             )
           ) == ["new"]
  end
end
