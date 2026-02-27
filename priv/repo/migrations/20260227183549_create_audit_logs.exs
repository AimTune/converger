defmodule Converger.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, on_delete: :nilify_all, type: :uuid), null: true

      add :actor_type, :text, null: false
      add :actor_id, :text, null: false

      add :action, :text, null: false
      add :resource_type, :text, null: false
      add :resource_id, :uuid, null: false

      add :changes, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_logs, [:tenant_id])
    create index(:audit_logs, [:resource_type, :resource_id])
    create index(:audit_logs, [:actor_type, :actor_id])
    create index(:audit_logs, [:action])
    create index(:audit_logs, [:inserted_at])
  end
end
