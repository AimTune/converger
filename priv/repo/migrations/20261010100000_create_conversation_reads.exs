defmodule Converger.Repo.Migrations.CreateConversationReads do
  use Ecto.Migration

  # Per-reader read watermark of a conversation: the highest activity `seq`
  # a WebSocket participant has marked as read (`read` frame). It only moves
  # forward; the upsert in Converger.Receipts enforces that.
  def change do
    create table(:conversation_reads, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :tenant_id, references(:tenants, on_delete: :delete_all, type: :uuid), null: false

      add :conversation_id, references(:conversations, on_delete: :delete_all, type: :uuid),
        null: false

      add :reader_id, :text, null: false
      add :read_seq, :bigint, null: false
      add :read_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversation_reads, [:conversation_id, :reader_id])
    create index(:conversation_reads, [:tenant_id])
  end
end
