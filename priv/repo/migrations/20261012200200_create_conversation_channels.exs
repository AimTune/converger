defmodule Converger.Repo.Migrations.CreateConversationChannels do
  use Ecto.Migration

  # Reply-back routing (#43, ADR-0046): a conversation records the channel it
  # started on (`origin_channel_id`) and spans channels through the
  # `conversation_channels` join table (its origin, the channels the pipeline
  # routed it to, and the channels that wrote into it).
  #
  # Existing conversations are backfilled in batches, outside one long
  # transaction: `origin_channel_id` from `channel_id` and one `origin` row
  # each (with the conversation's participant). The code falls back to
  # `channel_id` while `origin_channel_id` is still NULL, so the old and the
  # new release both work during a rolling deploy and an interrupted backfill
  # is simply resumed by running the migration again.
  @disable_ddl_transaction true

  @batch 5_000

  def up do
    locked(fn ->
      q("ALTER TABLE conversations ADD COLUMN IF NOT EXISTS origin_channel_id uuid")

      q("""
      CREATE TABLE IF NOT EXISTS conversation_channels (
        id uuid PRIMARY KEY,
        conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        channel_id uuid NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
        tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
        role varchar(16) NOT NULL,
        participant_id uuid REFERENCES participants(id) ON DELETE SET NULL,
        inserted_at timestamp(6) without time zone NOT NULL,
        updated_at timestamp(6) without time zone NOT NULL
      )
      """)

      q("""
      CREATE UNIQUE INDEX IF NOT EXISTS conversation_channels_conversation_id_channel_id_index
        ON conversation_channels (conversation_id, channel_id)
      """)

      q("""
      CREATE INDEX IF NOT EXISTS conversation_channels_channel_id_index
        ON conversation_channels (channel_id)
      """)

      q("""
      CREATE INDEX IF NOT EXISTS conversation_channels_tenant_id_index
        ON conversation_channels (tenant_id)
      """)

      q("""
      CREATE INDEX IF NOT EXISTS conversation_channels_participant_id_index
        ON conversation_channels (participant_id) WHERE participant_id IS NOT NULL
      """)
    end)

    backfill_origin()
    backfill_rows(nil)
  end

  def down do
    q("DROP TABLE IF EXISTS conversation_channels")
    q("ALTER TABLE conversations DROP COLUMN IF EXISTS origin_channel_id")
  end

  defp backfill_origin do
    %{num_rows: count} =
      q(
        """
        UPDATE conversations SET origin_channel_id = channel_id
        WHERE id IN (
          SELECT id FROM conversations WHERE origin_channel_id IS NULL LIMIT $1
        )
        """,
        [@batch]
      )

    if count == @batch, do: backfill_origin()
  end

  # Keyset over conversations.id, so each batch is an index range scan.
  defp backfill_rows(after_id) do
    %{rows: rows} =
      q(
        """
        SELECT id FROM conversations
        WHERE $1::uuid IS NULL OR id > $1::uuid
        ORDER BY id LIMIT $2
        """,
        [after_id, @batch]
      )

    case rows do
      [] ->
        :ok

      rows ->
        ids = Enum.map(rows, fn [id] -> id end)

        q(
          """
          INSERT INTO conversation_channels
            (id, conversation_id, channel_id, tenant_id, role, participant_id, inserted_at, updated_at)
          SELECT gen_random_uuid(), c.id, COALESCE(c.origin_channel_id, c.channel_id), c.tenant_id,
                 'origin', c.participant_id, c.inserted_at, c.inserted_at
          FROM conversations c
          WHERE c.id = ANY($1)
          ON CONFLICT (conversation_id, channel_id) DO NOTHING
          """,
          [ids]
        )

        if length(ids) == @batch,
          do: backfill_rows(List.last(ids))
    end
  end

  defp q(sql, params \\ []), do: repo().query!(sql, params, timeout: :infinity, log: :info)

  # Short DDL: fail fast instead of queueing traffic behind a lock.
  defp locked(fun) do
    repo().transaction(fn ->
      repo().query!("SET LOCAL lock_timeout = '5s'")
      fun.()
    end)
  end
end
