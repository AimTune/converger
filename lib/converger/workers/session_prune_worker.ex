defmodule Converger.Workers.SessionPruneWorker do
  @moduledoc """
  Deletes expired admin/portal sessions (`Converger.Accounts.Sessions.prune/1`,
  which also disconnects their LiveViews) and expired password reset tokens
  (`Converger.Accounts.PasswordReset.prune/0`). Runs every 10 minutes
  (ADR-0058).
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  alias Converger.Accounts.{PasswordReset, Sessions}

  @impl Oban.Worker
  def perform(_job) do
    sessions = Sessions.prune()
    tokens = PasswordReset.prune()

    if sessions + tokens > 0 do
      Logger.info("Pruned #{sessions} expired session(s) and #{tokens} account token(s)")
    end

    :ok
  end
end
