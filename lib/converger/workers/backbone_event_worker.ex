defmodule Converger.Workers.BackboneEventWorker do
  @moduledoc """
  Hands one backbone event to one shared subscription
  (`Converger.Backbone.Dispatch.handle/2`): the consumer of the Native
  backbone, and the durable retry of an event a broker consumer could not
  handle (`Converger.Backbone.Dispatch.consume/2` parks it here).

  Args: `"subscription"` (name) and `"event"` (`Converger.Backbone.Event.to_map/1`).
  A handler error is retried with Oban's backoff; with the subscription's
  receipts a retry never handles an event twice. A job for a subscription
  this node does not declare is retried too (a rolling deploy may run it on
  a node that does not know the subscription yet) until `max_attempts`.
  """
  use Oban.Worker, queue: :backbone, max_attempts: 20

  require Logger

  alias Converger.Backbone.{Dispatch, Event, Registry}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription" => name, "event" => map}}) do
    with {:subscription, subscription} when not is_nil(subscription) <-
           {:subscription, Registry.get(name)},
         {:event, {:ok, event}} <- {:event, Event.from_map(map)} do
      case Dispatch.handle(subscription, event) do
        {:ok, _outcome} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:subscription, nil} -> {:error, {:unknown_subscription, name}}
      {:event, {:error, reason}} -> {:cancel, {:invalid_event, reason}}
    end
  end
end
