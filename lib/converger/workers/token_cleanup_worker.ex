defmodule Converger.Workers.TokenCleanupWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    # Placeholder for token cleanup (not needed for stateless JWT)
    IO.puts("Token cleanup skipped (stateless JWT).")
    :ok
  end
end
