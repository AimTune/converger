defmodule Converger.Repo.Migrations.CreateCoreSchema do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"",
            "DROP EXTENSION IF EXISTS \"uuid-ossp\""

    execute "CREATE EXTENSION IF NOT EXISTS \"pgcrypto\"", "DROP EXTENSION IF EXISTS \"pgcrypto\""

    create table(:tenants, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :name, :text, null: false
      add :api_key, :text, null: false
      add :status, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenants, [:api_key])

    create table(:channels, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :tenant_id, references(:tenants, on_delete: :delete_all, type: :uuid), null: false
      add :name, :text, null: false
      add :secret, :text, null: false
      add :status, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channels, [:tenant_id, :name])

    create table(:conversations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :tenant_id, references(:tenants, on_delete: :delete_all, type: :uuid), null: false
      add :channel_id, references(:channels, on_delete: :delete_all, type: :uuid), null: false
      add :status, :text, null: false
      add :metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:tenant_id])
    create index(:conversations, [:channel_id])

    create table(:activities, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :tenant_id, references(:tenants, on_delete: :delete_all, type: :uuid), null: false

      add :conversation_id, references(:conversations, on_delete: :delete_all, type: :uuid),
        null: false

      add :type, :text
      add :sender, :text, null: false
      add :text, :text
      add :attachments, :map, default: "[]"
      add :metadata, :map, default: "{}"
      add :idempotency_key, :text

      # We manually add created_at with NOT NULL constraint because timestamps() sets it to NULL by default without extra setup or migration edit
      timestamps(type: :utc_datetime_usec)
    end

    create index(:activities, [:tenant_id])
    # Activities ordered by created_at (inserted_at in standard Ecto) for fast queries
    create index(:activities, [:conversation_id, :inserted_at])

    create unique_index(:activities, [:conversation_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL"
           )
  end
end
