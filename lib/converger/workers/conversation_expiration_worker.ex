defmodule Converger.Workers.ConversationExpirationWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query
  alias Converger.Repo
  alias Converger.Conversations.Conversation
  alias Converger.Activities.Activity

  @impl Oban.Worker
  def perform(_job) do
    threshold = DateTime.utc_now() |> DateTime.add(-24, :hour)

    # Find active conversations with no activities in the last 24 hours
    expired_conversations_query =
      from c in Conversation,
        as: :conversation,
        where: c.status == "active" and c.inserted_at < ^threshold,
        where:
          not exists(
            from a in Activity,
              where:
                a.conversation_id == parent_as(:conversation).id and a.inserted_at > ^threshold
          )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {count, _} =
      Repo.update_all(expired_conversations_query, set: [status: "closed", updated_at: now])

    Logger.info("Closed #{count} expired conversations.")
    :ok
  end
end
