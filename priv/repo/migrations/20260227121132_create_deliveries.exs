defmodule Converger.Repo.Migrations.CreateDeliveries do
  use Ecto.Migration

  def change do
    create table(:deliveries, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :activity_id, references(:activities, on_delete: :delete_all, type: :uuid), null: false
      add :channel_id, references(:channels, on_delete: :delete_all, type: :uuid), null: false
      add :status, :text, null: false, default: "pending"
      add :attempts, :integer, default: 0
      add :last_error, :text
      add :delivered_at, :utc_datetime_usec
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:deliveries, [:activity_id])
    create index(:deliveries, [:channel_id])
    create index(:deliveries, [:status])
    create unique_index(:deliveries, [:activity_id, :channel_id])
  end
end
