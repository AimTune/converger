defmodule Converger.Workers.PartitionMaintenanceWorker do
  @moduledoc """
  Daily: makes sure the monthly partitions of `activities` and `deliveries`
  exist for the current month and the next `:months_ahead` months
  (`Converger.Partitions.ensure_partitions/1`). An insert into a month
  without a partition fails, so partitions are created months in advance.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case Converger.Partitions.ensure_partitions() do
      [] -> :ok
      created -> Logger.info("Created partitions", partitions: Enum.join(created, ", "))
    end

    :ok
  end
end
