defmodule Converger.Repo.Migrations.AddReplyAndEditColumnsToActivities do
  use Ecto.Migration

  # Rich activity model (#28, ADR-0036): threaded replies and the targets of
  # messageReaction / messageUpdate / messageDelete (`reply_to_id`), and the
  # edit / delete markers the server stamps on the original activity.
  #
  # `activities` is partitioned by month (#30, ADR-0034), so:
  #
  #   * there is no foreign key: a partitioned table's primary key is
  #     (id, inserted_at), so `reply_to_id` alone cannot reference it, and
  #     retention drops whole months, which may leave references dangling.
  #     The same-conversation rule is enforced by Converger.Activities under
  #     the conversation row lock;
  #   * the index is created ON ONLY the parent (instant, invalid until every
  #     partition has it), built CONCURRENTLY on each attached partition and
  #     attached, so writers are never blocked. Partitions created later get
  #     it automatically on ATTACH PARTITION.
  #
  # Adding nullable columns without a default is metadata-only.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "activities_reply_to_id_index"

  def up do
    locked("""
    ALTER TABLE activities
      ADD COLUMN IF NOT EXISTS reply_to_id uuid,
      ADD COLUMN IF NOT EXISTS edited_at timestamp without time zone,
      ADD COLUMN IF NOT EXISTS deleted_at timestamp without time zone
    """)

    if partitioned?() do
      locked(
        "CREATE INDEX IF NOT EXISTS #{@index} ON ONLY activities (reply_to_id) WHERE reply_to_id IS NOT NULL"
      )

      for leaf <- partitions() do
        leaf_index = "#{leaf}_reply_to_id_index"

        q(
          "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{leaf_index} ON #{leaf} (reply_to_id) WHERE reply_to_id IS NOT NULL"
        )

        unless attached_index?(leaf_index) do
          locked("ALTER INDEX #{@index} ATTACH PARTITION #{leaf_index}")
        end
      end
    else
      q(
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index} ON activities (reply_to_id) WHERE reply_to_id IS NOT NULL"
      )
    end
  end

  def down do
    # Dropping the parent index drops the attached partition indexes too.
    q("DROP INDEX IF EXISTS #{@index}")

    q("""
    ALTER TABLE activities
      DROP COLUMN IF EXISTS deleted_at,
      DROP COLUMN IF EXISTS edited_at,
      DROP COLUMN IF EXISTS reply_to_id
    """)
  end

  # Statements run immediately (not queued like `execute/1`), because the
  # partition list is read in between.
  defp q(sql), do: repo().query!(sql, [], timeout: :infinity, log: :info)

  # Short DDL that needs a lock on `activities`: fail fast instead of queueing
  # traffic behind it. SET LOCAL keeps the timeout on this transaction's
  # connection. Concurrent index builds run without it (they wait for older
  # transactions by design).
  defp locked(sql) do
    repo().transaction(fn ->
      repo().query!("SET LOCAL lock_timeout = '5s'")
      repo().query!(sql, [], log: :info)
    end)
  end

  defp partitioned? do
    %{rows: [[relkind]]} =
      repo().query!("SELECT relkind::text FROM pg_class WHERE oid = to_regclass('activities')")

    relkind == "p"
  end

  defp partitions do
    %{rows: rows} =
      repo().query!("""
      SELECT c.relname
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
      WHERE i.inhparent = to_regclass('activities') AND c.relkind = 'r' AND NOT i.inhdetachpending
      ORDER BY c.relname
      """)

    List.flatten(rows)
  end

  defp attached_index?(leaf_index) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT 1 FROM pg_inherits
        WHERE inhrelid = to_regclass($1) AND inhparent = to_regclass($2)
        """,
        [leaf_index, @index]
      )

    rows != []
  end
end
