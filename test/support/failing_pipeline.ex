defmodule Converger.FailingPipeline do
  @moduledoc """
  Test pipeline backend that enqueues Oban jobs like `Converger.Pipeline.Oban`
  and then fails, to prove jobs and activity share one transaction.

  The failure mode is read from the process dictionary:

    * `:raise` (default) - raises after the jobs were inserted
    * `:error` - returns `{:error, :boom}` after the jobs were inserted
  """

  @behaviour Converger.Pipeline

  @impl true
  def child_specs, do: []

  @impl true
  def enqueue(activity) do
    :ok = Converger.Pipeline.Oban.enqueue(activity)

    case Process.get(:failing_pipeline_mode, :raise) do
      :raise -> raise "pipeline exploded after enqueue"
      :error -> {:error, :boom}
    end
  end

  @impl true
  def after_commit(_activity), do: :ok
end
