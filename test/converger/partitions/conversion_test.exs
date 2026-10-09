defmodule Converger.Partitions.ConversionTest do
  @moduledoc """
  The migration path for existing installations (issue #30): legacy plain
  `activities` / `deliveries` tables with data are converted into monthly
  partitioned tables (prepare + online copy with writes in between + swap).

  The legacy tables are created in a scratch schema that comes first in the
  `search_path` of the sandbox transaction, so the conversion runs against
  them exactly as it would against `public` on an existing installation,
  while `tenants`, `conversations` and `channels` resolve to `public`.
  Everything is rolled back with the sandbox.
  """
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Partitions
  alias Converger.Partitions.Conversion

  @legacy_ddl [
    "CREATE SCHEMA conv_test",
    "SET LOCAL search_path TO conv_test, public",
    """
    CREATE TABLE activities (
      id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
      tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
      conversation_id uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
      type text,
      sender text NOT NULL,
      text text,
      attachments jsonb DEFAULT '[]'::jsonb,
      metadata jsonb DEFAULT '{}'::jsonb,
      idempotency_key text,
      inserted_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      seq bigint NOT NULL
    )
    """,
    "CREATE UNIQUE INDEX activities_conversation_id_seq_index ON activities (conversation_id, seq)",
    "CREATE UNIQUE INDEX activities_conversation_id_idempotency_key_index ON activities (conversation_id, idempotency_key) WHERE idempotency_key IS NOT NULL",
    "CREATE INDEX activities_tenant_id_index ON activities (tenant_id)",
    """
    CREATE TABLE deliveries (
      id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
      activity_id uuid NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
      channel_id uuid NOT NULL REFERENCES public.channels(id) ON DELETE CASCADE,
      status text NOT NULL DEFAULT 'pending',
      attempts integer DEFAULT 0,
      last_error text,
      delivered_at timestamp without time zone,
      metadata jsonb DEFAULT '{}'::jsonb,
      inserted_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      sent_at timestamp without time zone,
      read_at timestamp without time zone,
      provider_message_id text
    )
    """,
    "CREATE UNIQUE INDEX deliveries_activity_id_channel_id_index ON deliveries (activity_id, channel_id)"
  ]

  setup do
    Enum.each(@legacy_ddl, &Repo.query!/1)

    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp insert_legacy_activity(ctx, seq, inserted_at, extra \\ %{}) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO activities (id, tenant_id, conversation_id, type, sender, text, idempotency_key,
                              metadata, inserted_at, updated_at, seq)
      VALUES ($1, $2, $3, 'message', 'user-1', $4, $5, $6, $7, $7, $8)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(ctx.tenant.id),
        Ecto.UUID.dump!(ctx.conversation.id),
        Map.get(extra, :text, "message #{seq}"),
        Map.get(extra, :idempotency_key),
        %{"n" => seq},
        inserted_at,
        seq
      ]
    )

    id
  end

  defp insert_legacy_delivery(ctx, activity_id, status) do
    id = Ecto.UUID.generate()
    now = ~N[2026-10-01 12:00:00]

    Repo.query!(
      """
      INSERT INTO deliveries (id, activity_id, channel_id, status, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $5)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(activity_id),
        Ecto.UUID.dump!(ctx.channel.id),
        status,
        now
      ]
    )

    id
  end

  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows

  test "converts populated legacy tables while writes continue between copy batches", ctx do
    # Existing data spread over three months.
    a1 = insert_legacy_activity(ctx, 1, ~N[2025-11-03 10:00:00], %{idempotency_key: "k1"})
    a2 = insert_legacy_activity(ctx, 2, ~N[2025-12-15 10:00:00])
    a3 = insert_legacy_activity(ctx, 3, ~N[2026-01-20 10:00:00])
    d1 = insert_legacy_delivery(ctx, a1, "sent")
    d2 = insert_legacy_delivery(ctx, a2, "pending")

    assert :ok = Conversion.prepare(Repo, today: ~D[2026-01-25])
    assert Conversion.prepared?(Repo)
    refute Conversion.converted?(Repo)

    # Monthly partitions from the oldest row's month to a year ahead.
    months = Partitions.attached("activities", parents: %{"activities" => "activities_part"})
    assert hd(months).month == ~D[2025-10-01]
    assert List.last(months).month == ~D[2027-01-01]

    # Copy in tiny batches, interleaved with "old release" writes.
    assert %{"activities" => 3, "deliveries" => 2} = Conversion.copy(Repo, batch_size: 1)

    # Writes after (and during) the copy are mirrored by the triggers.
    a4 = insert_legacy_activity(ctx, 4, ~N[2026-01-24 09:00:00])
    d4 = insert_legacy_delivery(ctx, a4, "pending")
    Repo.query!("UPDATE deliveries SET status = 'read' WHERE id = $1", [Ecto.UUID.dump!(d2)])
    Repo.query!("UPDATE activities SET text = 'edited' WHERE id = $1", [Ecto.UUID.dump!(a3)])
    # Deleting an activity cascades to its legacy deliveries; both mirror.
    Repo.query!("DELETE FROM activities WHERE id = $1", [Ecto.UUID.dump!(a1)])

    assert [[3]] = rows("SELECT count(*) FROM activities_part")
    assert [[2]] = rows("SELECT count(*) FROM deliveries_part")

    # A second copy run resumes from its cursor. Rows the triggers already
    # mirrored may be scanned again (their ids can sort after the cursor) but
    # are not duplicated.
    Conversion.copy(Repo)
    assert [[3]] = rows("SELECT count(*) FROM activities_part")
    assert [[2]] = rows("SELECT count(*) FROM deliveries_part")

    assert {:ok, %{"activities" => 3, "deliveries" => 2}} =
             Conversion.swap(Repo, today: ~D[2026-01-25])

    assert Conversion.converted?(Repo)
    refute Partitions.table_exists?(Repo, "partition_conversion_state")

    # The legacy tables are kept (renamed) on populated installations, without
    # foreign keys, and the triggers are gone.
    assert Partitions.table_exists?(Repo, "activities_legacy")
    assert Partitions.table_exists?(Repo, "deliveries_legacy")

    assert [] =
             rows("""
             SELECT conname FROM pg_constraint
             WHERE contype = 'f' AND conrelid IN (to_regclass('activities_legacy'),
                                                  to_regclass('deliveries_legacy'),
                                                  to_regclass('activities'),
                                                  to_regclass('deliveries'))
             """)

    assert [] = rows("SELECT tgname FROM pg_trigger WHERE tgname = 'converger_mirror'")

    # Index names moved with the tables.
    index_names = rows("SELECT indexname FROM pg_indexes WHERE schemaname = 'conv_test'")
    index_names = List.flatten(index_names)
    assert "activities_pkey" in index_names
    assert "activities_legacy_pkey" in index_names
    assert "deliveries_activity_id_channel_id_index" in index_names
    refute Enum.any?(index_names, &String.starts_with?(&1, "activities_part"))

    # Contents, including the mirrored update and delete, and the delivery's
    # new partition key and tenant.
    assert [["edited"]] =
             rows("SELECT text FROM activities WHERE id = $1", [Ecto.UUID.dump!(a3)])

    assert [] = rows("SELECT 1 FROM activities WHERE id = $1", [Ecto.UUID.dump!(a1)])
    assert [] = rows("SELECT 1 FROM deliveries WHERE id = $1", [Ecto.UUID.dump!(d1)])

    assert [["read", tenant, ~N[2025-12-15 10:00:00.000000]]] =
             rows(
               "SELECT status, tenant_id, activity_inserted_at FROM deliveries WHERE id = $1",
               [Ecto.UUID.dump!(d2)]
             )

    assert Ecto.UUID.load!(tenant) == ctx.tenant.id

    # A delivery lives in its activity's month, whatever its own inserted_at.
    assert [["deliveries_p2026_01"]] =
             rows("SELECT tableoid::regclass::text FROM deliveries WHERE id = $1", [
               Ecto.UUID.dump!(d4)
             ])

    # Rows landed in their month's partition.
    assert [["activities_p2025_12"]] =
             rows("SELECT tableoid::regclass::text FROM activities WHERE id = $1", [
               Ecto.UUID.dump!(a2)
             ])

    # Current and upcoming partitions exist after the swap.
    assert Enum.any?(Partitions.attached("activities"), &(&1.month == ~D[2026-04-01]))
  end

  test "an empty installation converts inline and drops the empty legacy tables", _ctx do
    assert {:ok, %{"activities" => :dropped, "deliveries" => :dropped}} = Conversion.run(Repo)
    assert Conversion.converted?(Repo)
    refute Partitions.table_exists?(Repo, "activities_legacy")
    # Idempotent.
    assert :ok = Conversion.run(Repo)
  end

  test "refuses to copy a large table inline unless prepared first", ctx do
    for seq <- 1..3, do: insert_legacy_activity(ctx, seq, ~N[2026-01-02 00:00:00])

    assert_raise RuntimeError, ~r/prepare_partitioning/, fn ->
      Conversion.run(Repo, max_inline_rows: 2)
    end

    refute Conversion.prepared?(Repo)

    # After the online prepare/copy the migration proceeds.
    Conversion.prepare(Repo)
    Conversion.copy(Repo)
    assert {:ok, %{"activities" => 3}} = Conversion.run(Repo, max_inline_rows: 2)
  end

  test "swap rolls back when the copy does not match", ctx do
    insert_legacy_activity(ctx, 1, ~N[2026-01-02 00:00:00])
    Conversion.prepare(Repo)
    Conversion.copy(Repo)

    # Simulate a lost row in the shadow table.
    Repo.query!("ALTER TABLE activities DISABLE TRIGGER converger_mirror")
    insert_legacy_activity(ctx, 2, ~N[2026-01-02 00:00:01])

    Repo.query!(
      "UPDATE partition_conversion_state SET cursor = 'ffffffff-ffff-ffff-ffff-ffffffffffff'"
    )

    assert_raise RuntimeError, ~r/nothing was swapped/, fn -> Conversion.swap(Repo) end
  end
end
