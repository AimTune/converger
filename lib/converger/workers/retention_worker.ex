defmodule Converger.Workers.RetentionWorker do
  @moduledoc """
  Monthly retention run (cron, `config/config.exs`): archives expired
  activities and deliveries to object storage and drops or deletes them, see
  `Converger.Retention.run/1`.

  Unique while incomplete, so a manual run (`Converger.Release.run_retention/0`)
  and the cron never overlap. A failed run is retried; every step is
  idempotent, so a retry continues where the previous attempt stopped.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case Converger.Retention.run() do
      {:ok, results} ->
        Enum.each(results, fn result ->
          Logger.info("Retention",
            month: Converger.Partitions.month_label(result.month),
            action: result.action
          )
        end)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Storage or database outages: back off up to about a day.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(trunc(:math.pow(2, attempt) * 60), 86_400)
end
