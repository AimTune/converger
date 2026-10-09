defmodule Converger.Workers.PruneWorker do
  @moduledoc """
  Daily time-based pruning of `channel_health_checks` and `audit_logs`
  (`Converger.Retention.prune/1`).
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    counts = Converger.Retention.prune()
    Logger.info("Pruned old rows", counts: inspect(counts))
    :ok
  end
end
