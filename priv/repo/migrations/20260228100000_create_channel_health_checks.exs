defmodule Converger.Repo.Migrations.CreateChannelHealthChecks do
  use Ecto.Migration

  def change do
    create table(:channel_health_checks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :channel_id, references(:channels, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :total_deliveries, :integer, null: false, default: 0
      add :failed_deliveries, :integer, null: false, default: 0
      add :failure_rate, :float, null: false, default: 0.0
      add :checked_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:channel_health_checks, [:channel_id])
    create index(:channel_health_checks, [:channel_id, :checked_at])
    create index(:channel_health_checks, [:checked_at])
  end
end
