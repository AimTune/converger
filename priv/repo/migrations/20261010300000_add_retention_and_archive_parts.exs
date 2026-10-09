defmodule Converger.Repo.Migrations.AddRetentionAndArchiveParts do
  use Ecto.Migration

  # Expand-only and rolling-deploy safe (issue #30): a column with a constant
  # default is metadata-only on Postgres 11+, and archive_parts is a new table.
  def change do
    alter table(:tenants) do
      # Activities and deliveries older than this are archived to object
      # storage and removed (Converger.Retention).
      add :retention_days, :integer, null: false, default: 365
    end

    create constraint(:tenants, :retention_days_positive, check: "retention_days > 0")

    # Manifest of archived JSONL.gz objects (Converger.Archive). No foreign
    # key to tenants: the manifest outlives a deleted tenant.
    create table(:archive_parts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, :uuid, null: false
      add :table_name, :text, null: false
      add :month, :date, null: false
      add :part, :integer, null: false
      # "detached" (exported from a detached month partition) or "deleted"
      # (exported and then deleted row by row from a live partition).
      add :mode, :text, null: false
      add :object_key, :text, null: false
      add :row_count, :integer, null: false
      add :byte_size, :bigint, null: false
      add :sha256, :text, null: false
      # Export cursor: the last (highest) id in this part.
      add :last_id, :uuid, null: false
      add :verified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:archive_parts, [:table_name, :tenant_id, :month, :part])
    create unique_index(:archive_parts, [:object_key])
    create index(:archive_parts, [:month, :table_name])
  end
end
