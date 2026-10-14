# The suite is one quote block on purpose: every backbone runs the same tests.
# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule Converger.BackboneConformance do
  @moduledoc """
  The conformance suite every `Converger.Backbone` implementation passes
  (issue #66, ADR-0070). A test module runs it against one backbone:

      defmodule Converger.Backbone.KafkaConformanceTest do
        use ExUnit.Case, async: false
        use Converger.BackboneConformance, backbone: Converger.Backbone.Kafka, ordered: true

        # setup: start the backbone's processes, return %{run: id}
        def deliver(_context), do: :ok           # make queued events run
        def crash_consumers(context, subscription), do: ...   # kill and restart
      end

  The using module defines:

    * `deliver(context)` - make published events reach the handlers (the
      Native backbone drains its Oban queue; broker consumers are running);
    * `crash_consumers(context, subscription)` - simulate a consumer crash
      in the middle of a stream (kill the consumer, let it restart; Native:
      re-run jobs whose result was lost).

  and a `setup` returning `:run` (a unique id, put into every event's data so
  a subscription only sees its own test's events).

  Observations: the handlers send `{:observed, subscription, event}` to the
  test process (at least once) and, in the same transaction as the event's
  idempotency receipt, write an "effect" row (an `audit_logs` row with
  `actor_id` = the subscription name and `resource_id` = the event id). The
  zero-loss checks require every published event to be observed and its
  effect to exist exactly once.
  """

  defmacro __using__(opts) do
    backbone = Keyword.fetch!(opts, :backbone)
    ordered = Keyword.get(opts, :ordered, false)
    timeout = Keyword.get(opts, :timeout, 60_000)

    quote do
      import Converger.BackboneConformance

      alias Converger.Backbone
      alias Converger.Backbone.Event

      @backbone unquote(backbone)
      @timeout unquote(timeout)

      describe "#{inspect(@backbone)} conformance" do
        test "declares the delivery guarantee of shared subscriptions" do
          assert @backbone.guarantee() in [:at_least_once, :best_effort]
          assert is_list(@backbone.child_specs())
        end

        test "a shared subscription receives every published event once, unchanged",
             context do
          sub = subscribe!(context, @backbone, :activities, "shared")

          events =
            for i <- 1..5 do
              event(context, :activities, %{"n" => i, "conversation_id" => "conv-#{i}"})
            end

          for event <- events, do: assert(:ok = publish_event(event))
          deliver(context)

          observed = await_observed(sub, Enum.map(events, & &1.id), @timeout)

          for event <- events do
            got = Map.fetch!(observed, event.id)
            assert got.type == event.type
            assert got.topic == :activities
            assert got.tenant_id == event.tenant_id
            assert got.key == event.key
            assert got.data == event.data
          end

          assert_effects_once(sub, events)
        end

        test "every shared subscription of a topic receives every event", context do
          first = subscribe!(context, @backbone, [:deliveries, :events], "first")
          second = subscribe!(context, @backbone, :deliveries, "second")

          delivery = event(context, :deliveries, %{"status" => "sent"})
          other = event(context, :events, %{"status" => "closed"})

          assert :ok = publish_event(delivery)
          assert :ok = publish_event(other)
          deliver(context)

          await_observed(first, [delivery.id, other.id], @timeout)
          await_observed(second, [delivery.id], @timeout)
          refute_observed(second, other.id)
          assert_effects_once(first, [delivery, other])
          assert_effects_once(second, [delivery])
        end

        test "a filter keeps unwanted events from the handler", context do
          sub =
            subscribe!(context, @backbone, :events, "filtered",
              filter: fn event ->
                event.data["run"] == context.run and event.data["wanted"] == true
              end
            )

          unwanted = event(context, :events, %{"wanted" => false})
          wanted = event(context, :events, %{"wanted" => true})

          assert :ok = publish_event(unwanted)
          assert :ok = publish_event(wanted)
          deliver(context)

          await_observed(sub, [wanted.id], @timeout)
          refute_observed(sub, unwanted.id)
        end

        test "a failing handler is retried until it succeeds; its effect applies once",
             context do
          failures = :counters.new(1, [])

          sub =
            subscribe!(context, @backbone, :events, "retried",
              fail_while: fn _event ->
                if :counters.get(failures, 1) < 2 do
                  :counters.add(failures, 1, 1)
                  true
                else
                  false
                end
              end
            )

          event = event(context, :events, %{"flaky" => true})
          assert :ok = publish_event(event)
          deliver(context)

          await_observed(sub, [event.id], @timeout)
          assert :counters.get(failures, 1) == 2
          assert_effects_once(sub, [event])
        end

        test "an event published twice (same id) is handled once", context do
          sub = subscribe!(context, @backbone, :activities, "dedup")
          event = event(context, :activities, %{"dup" => true})

          assert :ok = publish_event(event)
          assert :ok = publish_event(event)
          deliver(context)

          await_observed(sub, [event.id], @timeout)
          # Give the second copy time to arrive and be skipped.
          Process.sleep(1_000)
          deliver(context)
          assert_effects_once(sub, [event])
        end

        test "a broadcast subscription receives published events", context do
          sub = subscribe!(context, @backbone, :events, "bcast", mode: :broadcast)
          # Broadcast consumers start at the latest position: wait until ready.
          await_ready(context, &publish_event/1, sub, @timeout)

          event = event(context, :events, %{"broadcast" => true})
          assert :ok = publish_event(event)
          deliver(context)

          await_observed(sub, [event.id], @timeout)
        end

        if unquote(ordered) do
          test "events with the same key are handled in publish order", context do
            sub = subscribe!(context, @backbone, :activities, "ordered")

            events =
              for i <- 1..30,
                  do: event(context, :activities, %{"n" => i, "conversation_id" => "same"})

            for event <- events, do: assert(:ok = publish_event(event))
            deliver(context)

            await_observed(sub, Enum.map(events, & &1.id), @timeout)
            assert observed_order(sub) == Enum.map(events, & &1.id)
          end
        end

        test "zero loss: acked events survive a consumer crash, each applied exactly once",
             context do
          sub = subscribe!(context, @backbone, :activities, "zeroloss", slow_ms: 20)
          n = 60

          first =
            for i <- 1..n,
                do: event(context, :activities, %{"n" => i, "conversation_id" => "c#{rem(i, 7)}"})

          # Every publish is acknowledged by the backbone.
          for event <- first, do: assert(:ok = publish_event(event))

          # Let the consumer get part of the way, then crash it mid-stream.
          deliver_partially(context)
          await_count(sub, div(n, 4), @timeout)
          crash_consumers(context, sub)

          second =
            for i <- (n + 1)..(2 * n),
                do: event(context, :activities, %{"n" => i, "conversation_id" => "c#{rem(i, 7)}"})

          for event <- second, do: assert(:ok = publish_event(event))
          deliver(context)

          all = first ++ second
          await_observed(sub, Enum.map(all, & &1.id), @timeout)
          assert_effects_once(sub, all)
        end
      end

      # Overridable: how the suite publishes (the Native backbone publishes
      # in Oban's manual testing mode).
      def publish_event(event), do: Backbone.do_publish(@backbone, event)

      # Overridable: the Native backbone drains only part of its queue.
      def deliver_partially(context), do: deliver(context)
      defoverridable deliver_partially: 1, publish_event: 1
    end
  end

  import ExUnit.Assertions

  alias Converger.Backbone
  alias Converger.Backbone.Event
  alias Converger.Repo

  @doc "A unique run id for the test's events."
  def run_id, do: "run-#{System.unique_integer([:positive])}"

  @doc "An event of the test run (`context.run` in its data)."
  def event(context, topic, data) do
    Event.new(topic, %{
      type: type_of(topic),
      tenant_id: Ecto.UUID.generate(),
      data: Map.put(data, "run", context.run)
    })
  end

  defp type_of(:activities), do: "activity.created"
  defp type_of(:deliveries), do: "delivery.sent"
  defp type_of(:events), do: "conversation.closed"

  @doc """
  Subscribe a recording handler. Options: `:mode`, `:filter` (default: the
  run's events), `:fail_while` (a predicate; the handler returns an error
  while it is true), `:slow_ms` (handler delay).
  """
  def subscribe!(context, backbone, topics, label, opts \\ []) do
    test_pid = self()
    name = "t#{System.unique_integer([:positive])}-#{label}"
    fail_while = Keyword.get(opts, :fail_while, fn _ -> false end)
    slow_ms = Keyword.get(opts, :slow_ms, 0)
    mode = Keyword.get(opts, :mode, :shared)

    handler = fn event ->
      if slow_ms > 0, do: Process.sleep(slow_ms)

      if fail_while.(event) do
        {:error, :induced_failure}
      else
        record_effect(name, event, mode)
        send(test_pid, {:observed, name, event})
        :ok
      end
    end

    filter = Keyword.get(opts, :filter, fn event -> event.data["run"] == context.run end)

    {:ok, subscription} =
      Backbone.subscribe(topics, handler,
        name: name,
        mode: mode,
        filter: filter,
        backbone: backbone,
        concurrency: Keyword.get(opts, :concurrency, 4)
      )

    ExUnit.Callbacks.on_exit(fn -> Backbone.unsubscribe(subscription, backbone: backbone) end)
    subscription
  end

  defp record_effect(_name, _event, :broadcast), do: :ok

  defp record_effect(name, event, :shared) do
    {1, _} =
      Repo.insert_all("audit_logs", [
        %{
          id: Ecto.UUID.bingenerate(),
          actor_type: "system",
          actor_id: name,
          action: "backbone_conformance",
          resource_type: "backbone_event",
          resource_id: Ecto.UUID.dump!(event.id),
          inserted_at: DateTime.utc_now()
        }
      ])

    :ok
  end

  @doc "Wait until every id in `ids` was observed by `subscription`; returns id => event."
  def await_observed(subscription, ids, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(subscription.name, MapSet.new(ids), %{}, deadline)
  end

  defp collect(name, missing, seen, deadline) do
    if MapSet.size(missing) == 0 do
      seen
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:observed, ^name, event} ->
          record_order(name, event.id)

          collect(
            name,
            MapSet.delete(missing, event.id),
            Map.put(seen, event.id, event),
            deadline
          )
      after
        remaining ->
          flunk("#{MapSet.size(missing)} event(s) never observed by #{name}")
      end
    end
  end

  defp record_order(name, id) do
    key = {:backbone_order, name}
    Process.put(key, [id | Process.get(key, [])])
  end

  @doc "The order in which `await_observed/3` saw the subscription's events."
  def observed_order(subscription),
    do: {:backbone_order, subscription.name} |> Process.get([]) |> Enum.reverse() |> Enum.uniq()

  @doc "Refute that `id` was observed (within 500 ms)."
  def refute_observed(subscription, id) do
    name = subscription.name
    refute_receive {:observed, ^name, %{id: ^id}}, 500
  end

  @doc "Wait until `count` effects of the subscription exist."
  def await_count(subscription, count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_count_until(subscription.name, count, deadline)
  end

  defp await_count_until(name, count, deadline) do
    current = effect_count(name)

    cond do
      current >= count ->
        current

      System.monotonic_time(:millisecond) > deadline ->
        flunk("only #{current} of #{count} effects of #{name}")

      true ->
        Process.sleep(50)
        await_count_until(name, count, deadline)
    end
  end

  defp effect_count(name) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_logs WHERE actor_id = $1 AND action = 'backbone_conformance'",
        [name]
      )

    count
  end

  @doc """
  Every event's effect exists exactly once (and nothing else). A handler
  reports an event before its transaction commits: effects still missing
  are waited for up to 10 s.
  """
  def assert_effects_once(subscription, events, tries \\ 100) do
    counts = effect_counts(subscription.name)

    if tries > 0 and Enum.any?(events, &(not Map.has_key?(counts, &1.id))) do
      Process.sleep(100)
      assert_effects_once(subscription, events, tries - 1)
    else
      check_effects(counts, events)
    end
  end

  defp effect_counts(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT resource_id, count(*) FROM audit_logs " <>
          "WHERE actor_id = $1 AND action = 'backbone_conformance' GROUP BY resource_id",
        [name]
      )

    Map.new(rows, fn [id, count] -> {Ecto.UUID.cast!(id), count} end)
  end

  defp check_effects(counts, events) do
    expected = Map.new(events, &{&1.id, 1})

    duplicated = for {id, count} <- counts, count > 1, do: id
    missing = for event <- events, not Map.has_key?(counts, event.id), do: event.id

    assert duplicated == [], "effects applied more than once: #{inspect(duplicated)}"
    assert missing == [], "effects never applied: #{inspect(missing)}"
    assert counts == expected
  end

  @doc """
  Wait until a broadcast subscription's consumer is in place: publish probe
  events until one is observed.
  """
  def await_ready(context, publish, subscription, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    probe_until_observed(context, publish, subscription, deadline)
  end

  defp probe_until_observed(context, publish, subscription, deadline) do
    probe = event(context, hd(subscription.topics), %{"probe" => true})
    :ok = publish.(probe)
    name = subscription.name

    receive do
      {:observed, ^name, %{data: %{"probe" => true}}} -> :ok
    after
      1_000 ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("broadcast subscription #{name} never became ready"),
          else: probe_until_observed(context, publish, subscription, deadline)
    end
  end

  @doc "Delete the effect rows and receipts of a run's subscriptions (no sandbox)."
  def cleanup_effects(prefix) do
    Repo.query!(
      "DELETE FROM audit_logs WHERE action = 'backbone_conformance' AND actor_id LIKE $1",
      [
        prefix <> "%"
      ]
    )

    Repo.query!("DELETE FROM backbone_receipts WHERE subscription LIKE $1", [prefix <> "%"])
    :ok
  end
end
