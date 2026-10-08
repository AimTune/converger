defmodule Converger.Repo.Migrations.AddSeqToActivities do
  use Ecto.Migration

  def up do
    alter table(:conversations) do
      add :last_seq, :bigint, null: false, default: 0
    end

    alter table(:activities) do
      add :seq, :bigint
    end

    flush()

    Enum.each(backfill_statements(), &execute/1)

    alter table(:activities) do
      modify :seq, :bigint, null: false
    end

    create unique_index(:activities, [:conversation_id, :seq])
  end

  def down do
    drop index(:activities, [:conversation_id, :seq])

    alter table(:activities) do
      remove :seq
    end

    alter table(:conversations) do
      remove :last_seq
    end
  end

  @doc """
  Number existing activities per conversation in their historical
  (inserted_at, id) order and set each conversation's counter to its max.
  Public so the backfill can be tested.
  """
  def backfill_statements do
    [
      """
      UPDATE activities AS a
      SET seq = numbered.rn
      FROM (
        SELECT id,
               row_number() OVER (PARTITION BY conversation_id ORDER BY inserted_at, id) AS rn
        FROM activities
      ) AS numbered
      WHERE a.id = numbered.id
      """,
      """
      UPDATE conversations AS c
      SET last_seq = COALESCE((SELECT max(seq) FROM activities WHERE conversation_id = c.id), 0)
      """
    ]
  end
end
