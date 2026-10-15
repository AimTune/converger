defmodule Converger.Workers.PurgeWorker do
  @moduledoc """
  Deletes the activities and deliveries left behind by deleting a tenant,
  a channel or a conversation, in batches.

  The partitioned `activities` and `deliveries` tables have no foreign keys
  (ADR-0034), so there is no `ON DELETE CASCADE` into them. Deleting a
  tenant used to cascade into every activity and delivery in one statement,
  holding locks and generating WAL for hours on a large tenant; now the
  tenant row (with its channels and conversations) is deleted at once and
  this job, enqueued in the same transaction, removes the rest
  `:batch_size` rows per statement.

  Args, one of:

    * `%{"tenant_id" => id}` - all activities and deliveries of the tenant
    * `%{"channel_id" => id}` - deliveries to the channel
    * `%{"conversation_ids" => [id, ...]}` - activities of these
      conversations and their deliveries
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 20

  import Ecto.Query, warn: false

  alias Converger.Repo

  @batch_size 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    purge(args)
    :ok
  end

  @doc "Runs a purge synchronously. Returns the number of rows deleted."
  def purge(%{"tenant_id" => tenant_id}) do
    id = Ecto.UUID.dump!(tenant_id)

    delete_in_batches(
      "DELETE FROM deliveries WHERE id IN (SELECT id FROM deliveries WHERE tenant_id = $1 LIMIT $2)",
      [id]
    ) +
      delete_in_batches(
        "DELETE FROM activities WHERE id IN (SELECT id FROM activities WHERE tenant_id = $1 LIMIT $2)",
        [id]
      )
  end

  def purge(%{"channel_id" => channel_id}) do
    delete_in_batches(
      "DELETE FROM deliveries WHERE id IN (SELECT id FROM deliveries WHERE channel_id = $1 LIMIT $2)",
      [Ecto.UUID.dump!(channel_id)]
    )
  end

  def purge(%{"conversation_ids" => ids}) when is_list(ids) do
    ids = Enum.map(ids, &Ecto.UUID.dump!/1)

    delete_in_batches(
      """
      DELETE FROM deliveries WHERE id IN (
        SELECT d.id FROM deliveries d
        JOIN activities a ON a.id = d.activity_id AND a.inserted_at = d.activity_inserted_at
        WHERE a.conversation_id = ANY($1::uuid[]) LIMIT $2
      )
      """,
      [ids]
    ) +
      delete_in_batches(
        "DELETE FROM activities WHERE id IN " <>
          "(SELECT id FROM activities WHERE conversation_id = ANY($1::uuid[]) LIMIT $2)",
        [ids]
      )
  end

  @doc """
  Purge jobs for the given conversation ids, `chunk` ids per job (for
  `Oban.insert_all/1`).
  """
  def conversation_jobs(ids, chunk \\ 1_000) do
    ids
    |> Enum.chunk_every(chunk)
    |> Enum.map(&new(%{conversation_ids: &1}))
  end

  # `sql` is one of the literal statements above.
  # sobelow_skip ["SQL.Query"]
  defp delete_in_batches(sql, params, total \\ 0) do
    %{num_rows: n} = Repo.query!(sql, params ++ [@batch_size], timeout: :infinity)

    if n < @batch_size, do: total + n, else: delete_in_batches(sql, params, total + n)
  end
end
