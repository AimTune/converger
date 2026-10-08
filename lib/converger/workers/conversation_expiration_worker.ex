defmodule Converger.Workers.ConversationExpirationWorker do
  @moduledoc """
  Hourly cron job: closes open conversations that have had no activity for
  the inactivity window (`config :converger, :conversation_inactivity_hours`,
  default 24; a job may override it with an `"inactivity_hours"` arg).

  Uses `conversations.updated_at` (bumped on every activity insert) and the
  `(status, updated_at)` index. See `Converger.Conversations.expire_inactive_conversations/1`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Converger.Conversations

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts =
      case args do
        %{"inactivity_hours" => hours} when is_integer(hours) and hours > 0 ->
          [inactivity_hours: hours]

        _ ->
          []
      end

    {:ok, count} = Conversations.expire_inactive_conversations(opts)

    Logger.info("Closed #{count} expired conversations.")
    :ok
  end
end
