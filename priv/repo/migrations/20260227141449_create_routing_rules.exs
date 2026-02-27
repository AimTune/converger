defmodule Converger.Repo.Migrations.CreateRoutingRules do
  use Ecto.Migration

  def change do
    create table(:routing_rules, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, on_delete: :delete_all, type: :uuid), null: false
      add :name, :text, null: false

      add :source_channel_id, references(:channels, on_delete: :delete_all, type: :uuid),
        null: false

      add :target_channel_ids, {:array, :uuid}, null: false, default: []
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:routing_rules, [:tenant_id])
    create index(:routing_rules, [:source_channel_id])
    create unique_index(:routing_rules, [:tenant_id, :name])
  end
end
