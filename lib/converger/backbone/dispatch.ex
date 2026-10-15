defmodule Converger.Backbone.Dispatch do
  @moduledoc """
  Hands an event to a subscription's handler. Every backbone calls this:
  the Native job worker (`Converger.Workers.BackboneEventWorker`), the
  broker consumers (`Converger.Backbone.Pipeline`) and the Native broadcast
  subscriber.

  ## Exactly once, the "-ish"

  Brokers and Oban deliver at least once: a consumer that crashed after
  handling an event but before acknowledging it sees the event again. A
  subscription with `dedup: true` therefore records an idempotency receipt
  (`backbone_receipts`, unique on subscription and event id) in the same
  database transaction as the handler: a redelivered event finds the
  receipt and is skipped, and a handler that fails rolls the receipt back
  so the event is retried. The handler's database writes thus commit
  exactly once per event id; anything it does outside the database is at
  least once.

  ## Failures on broker consumers

  `consume/2` retries a failing handler in place (`inline_attempts`, short
  backoff), then parks the event in Postgres as a
  `Converger.Workers.BackboneEventWorker` job that retries it durably
  ("the broker for throughput, Oban for retries", as the Broadway pipeline
  does for deliveries). If even parking fails (the database is down) it
  keeps retrying with backoff and never acknowledges an event it could not
  hand over, so a broker consumer blocks rather than loses.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Converger.Backbone.{Event, Subscription}
  alias Converger.Repo

  @doc """
  Whether `subscription` wants `event`: its `filter`, else the handler
  module's `accept?/1`, else `true`. Never raises.
  """
  @spec accept?(Subscription.t(), Event.t()) :: boolean()
  def accept?(%Subscription{} = subscription, %Event{} = event) do
    cond do
      not Subscription.topic?(subscription, event.topic) -> false
      is_function(subscription.filter, 1) -> subscription.filter.(event) == true
      module_accept?(subscription.handler) -> subscription.handler.accept?(event) == true
      true -> true
    end
  rescue
    error ->
      Logger.error("Backbone subscription filter raised",
        subscription: subscription.name,
        event_id: event.id,
        error: Exception.message(error)
      )

      # Let the handler decide: dropping the event here would lose it.
      true
  end

  defp module_accept?(handler),
    do: is_atom(handler) and function_exported?(handler, :accept?, 1)

  @doc """
  Handle `event` once for `subscription`. Returns `{:ok, :handled}`,
  `{:ok, :duplicate}` (a receipt exists), `{:ok, :skipped}` (filtered out)
  or `{:error, reason}`.
  """
  @spec handle(Subscription.t(), Event.t()) ::
          {:ok, :handled | :duplicate | :skipped} | {:error, term()}
  def handle(%Subscription{} = subscription, %Event{} = event) do
    start = System.monotonic_time()

    result =
      cond do
        not accept?(subscription, event) -> {:ok, :skipped}
        subscription.dedup -> handle_once(subscription, event)
        true -> with :ok <- call(subscription, event), do: {:ok, :handled}
      end

    :telemetry.execute(
      [:converger, :backbone, :handle],
      %{duration: System.monotonic_time() - start},
      %{
        subscription: subscription.name,
        topic: event.topic,
        type: event.type,
        outcome: outcome(result)
      }
    )

    result
  end

  defp outcome({:ok, outcome}), do: outcome
  defp outcome({:error, _}), do: :error

  defp handle_once(subscription, event) do
    Repo.transaction(fn ->
      if record_receipt(subscription.name, event.id) do
        case call(subscription, event) do
          :ok -> :handled
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        :duplicate
      end
    end)
  end

  # true when this call wrote the receipt.
  defp record_receipt(name, event_id) do
    {count, _} =
      Repo.insert_all(
        "backbone_receipts",
        [%{subscription: name, event_id: dump_uuid(event_id), inserted_at: DateTime.utc_now()}],
        on_conflict: :nothing,
        conflict_target: [:subscription, :event_id]
      )

    count == 1
  end

  defp dump_uuid(id) do
    case Ecto.UUID.dump(id) do
      {:ok, binary} -> binary
      :error -> raise ArgumentError, "backbone event id must be a UUID, got: #{inspect(id)}"
    end
  end

  defp call(%Subscription{handler: handler}, event) when is_function(handler, 1),
    do: normalize(handler.(event))

  defp call(%Subscription{handler: handler}, event), do: normalize(handler.handle_event(event))

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, _} = error), do: error
  defp normalize(other), do: {:error, {:unexpected_return, other}}

  @doc "Whether `subscription` has handled `event_id` (a receipt exists)."
  @spec handled?(String.t(), String.t()) :: boolean()
  def handled?(name, event_id) do
    Repo.exists?(
      from(r in "backbone_receipts",
        where: r.subscription == ^name and r.event_id == type(^event_id, :binary_id)
      )
    )
  end

  @doc """
  Handle `event` on a broker consumer: `handle/2`, retried in place, then
  parked as a durable job. Returns once the event is handled or parked;
  only then may the consumer acknowledge it.
  """
  @spec consume(Subscription.t(), Event.t()) :: :handled | :duplicate | :skipped | :parked
  def consume(%Subscription{} = subscription, %Event{} = event) do
    consume(subscription, event, 1)
  end

  defp consume(subscription, event, attempt) do
    case safe_handle(subscription, event) do
      {:ok, outcome} ->
        outcome

      {:error, reason} ->
        if attempt < config(:inline_attempts, 3) do
          Process.sleep(backoff(attempt, config(:inline_backoff_ms, 200)))
          consume(subscription, event, attempt + 1)
        else
          park(subscription, event, reason, 1)
        end
    end
  end

  defp safe_handle(subscription, event) do
    handle(subscription, event)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp park(%Subscription{mode: :broadcast} = subscription, event, reason, _attempt) do
    # Broadcast subscriptions are best effort: nothing to park for.
    Logger.warning("Backbone broadcast handler failed; event dropped",
      subscription: subscription.name,
      event_id: event.id,
      error: inspect(reason)
    )

    :skipped
  end

  defp park(subscription, event, reason, attempt) do
    job =
      Converger.Workers.BackboneEventWorker.new(%{
        "subscription" => subscription.name,
        "event" => Event.to_map(event)
      })

    case Oban.insert(job) do
      {:ok, _job} ->
        Logger.warning("Backbone event parked for durable retry",
          subscription: subscription.name,
          event_id: event.id,
          error: inspect(reason)
        )

        :parked

      {:error, park_error} ->
        retry_park(subscription, event, park_error, attempt)
    end
  rescue
    error -> retry_park(subscription, event, error, attempt)
  catch
    :exit, exit_reason -> retry_park(subscription, event, {:exit, exit_reason}, attempt)
  end

  defp retry_park(subscription, event, error, attempt) do
    Logger.error("Backbone event could not be parked; retrying",
      subscription: subscription.name,
      event_id: event.id,
      error: inspect(error)
    )

    Process.sleep(min(backoff(attempt, 500), config(:max_backoff_ms, 30_000)))
    park(subscription, event, error, attempt + 1)
  end

  defp backoff(attempt, base), do: base * Integer.pow(2, min(attempt - 1, 10))

  defp config(key, default) do
    :converger |> Application.get_env(Converger.Backbone, []) |> Keyword.get(key, default)
  end
end
