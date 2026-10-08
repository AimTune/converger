defmodule Converger.Repo.Migrations.AddConversationLifecycleIndex do
  use Ecto.Migration

  # `updated_at` is now bumped on every activity insert and is what the
  # expiration worker scans by. Historically it was not, so move it forward to
  # the latest activity first; otherwise every old conversation with recent
  # activity would be closed on the first run after deploy.
  def up do
    execute """
    UPDATE conversations AS c
    SET updated_at = latest.inserted_at
    FROM (
      SELECT conversation_id, max(inserted_at) AS inserted_at
      FROM activities
      GROUP BY conversation_id
    ) AS latest
    WHERE c.id = latest.conversation_id AND latest.inserted_at > c.updated_at
    """

    create index(:conversations, [:status, :updated_at])
  end

  def down do
    drop index(:conversations, [:status, :updated_at])
  end
end
