defmodule Converger.Repo.Migrations.CreateAttachments do
  use Ecto.Migration

  def change do
    create table(:attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all)

      add :activity_id, references(:activities, type: :binary_id, on_delete: :nilify_all)
      add :storage_key, :text, null: false
      add :content_type, :text, null: false
      add :size, :bigint, null: false
      add :sha256, :text, null: false
      add :filename, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:attachments, [:tenant_id])
    create index(:attachments, [:conversation_id])
    create index(:attachments, [:activity_id])
    create unique_index(:attachments, [:storage_key])

    # Optional per-tenant MIME allowlist; NULL means "use the global default".
    alter table(:tenants) do
      add :allowed_upload_types, {:array, :text}
    end
  end
end
