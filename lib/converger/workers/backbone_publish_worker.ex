defmodule Converger.Workers.BackbonePublishWorker do
  @moduledoc """
  Publishes a backbone event that a broker refused or could not be reached
  for (`Converger.Backbone.publish/2` parks it here), retrying with Oban's
  backoff until the broker accepts it. The event keeps its id, so a publish
  that did reach the broker before failing is a duplicate its consumers'
  receipts skip.

  Args: `"backbone"` (`kafka`, `nats`, `rabbitmq`) and `"event"`.
  """
  use Oban.Worker, queue: :backbone, max_attempts: 50

  alias Converger.Backbone
  alias Converger.Backbone.Event

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"backbone" => name, "event" => map}}) do
    with {:backbone, module} when not is_nil(module) <- {:backbone, Backbone.module_for(name)},
         {:event, {:ok, event}} <- {:event, Event.from_map(map)} do
      Backbone.do_publish(module, event)
    else
      {:backbone, nil} -> {:cancel, {:unknown_backbone, name}}
      {:event, {:error, reason}} -> {:cancel, {:invalid_event, reason}}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(trunc(:math.pow(2, attempt)), 300)
end
