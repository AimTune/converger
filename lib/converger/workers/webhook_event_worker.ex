defmodule Converger.Workers.WebhookEventWorker do
  @moduledoc """
  Delivers one platform webhook event (`Converger.Webhooks.Event`) to its
  subscription (ADR-0053).

  The event row's `attempts` and the shared retry policy
  (`Converger.Pipeline.RetryPolicy.default/0`, `config :converger,
  :retry_policy`) decide when to stop, like channel deliveries: a transient
  failure is retried with the policy backoff (or the receiver's
  `Retry-After`); a permanent one (a `4xx` other than 408/425/429, a blocked
  target) or the last allowed attempt dead-letters the event (`failed`) and
  cancels the job. Dead-lettered events can be redelivered
  (`Converger.Webhooks.redeliver/2`). `max_attempts` here is only a safety
  cap.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 100

  require Logger

  alias Converger.Channels.DeliveryError
  alias Converger.Pipeline
  alias Converger.Pipeline.RetryPolicy
  alias Converger.Repo
  alias Converger.Webhooks
  alias Converger.Webhooks.{Event, Sender}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => id}}) do
    case Repo.get(Event, id) do
      %Event{status: "pending"} = event -> deliver(Repo.preload(event, :subscription))
      %Event{} -> :ok
      nil -> {:cancel, :event_not_found}
    end
  end

  defp deliver(%Event{subscription: %{enabled: true} = subscription} = event) do
    case Sender.deliver(subscription, event) do
      {:ok, status} ->
        {:ok, _} = Webhooks.mark_delivered(event, status)
        telemetry(:delivered, event)
        :ok

      {:error, %DeliveryError{} = error} ->
        failed(event, error)
    end
  end

  defp deliver(%Event{} = event) do
    {:ok, _} = Webhooks.mark_dead(event, "subscription disabled")
    telemetry(:dead_lettered, event)
    {:cancel, :subscription_disabled}
  end

  defp failed(event, error) do
    policy = RetryPolicy.default()
    message = DeliveryError.message(error)
    dead? = not error.retryable? or RetryPolicy.exhausted?(policy, event.attempts + 1)

    {:ok, _} = Webhooks.mark_attempt_failed(event, message, error.status, dead?)

    Logger.warning("Platform webhook attempt failed",
      webhook_event_id: event.id,
      subscription_id: event.subscription_id,
      event_type: event.type,
      attempt: event.attempts + 1,
      dead_lettered: dead?,
      error: message
    )

    if dead? do
      telemetry(:dead_lettered, event)
      {:cancel, message}
    else
      telemetry(:failed, event)
      {:error, error}
    end
  end

  # The receiver's Retry-After wins; otherwise the shared policy backoff.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt} = job) do
    delay_ms = Pipeline.retry_delay_ms(RetryPolicy.default(), attempt, delivery_error(job))
    max(div(delay_ms, 1000), 1)
  end

  defp delivery_error(%Oban.Job{unsaved_error: %{reason: reason}}), do: unwrap(reason)
  defp delivery_error(_job), do: nil

  defp unwrap(%Oban.PerformError{reason: {:error, %DeliveryError{} = error}}), do: error
  defp unwrap(%DeliveryError{} = error), do: error
  defp unwrap(_), do: nil

  defp telemetry(name, event) do
    :telemetry.execute([:converger, :webhooks, name], %{count: 1}, %{
      tenant_id: event.tenant_id,
      subscription_id: event.subscription_id,
      type: event.type
    })
  end
end
