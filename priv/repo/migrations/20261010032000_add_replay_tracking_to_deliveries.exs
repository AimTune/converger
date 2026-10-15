defmodule Converger.Repo.Migrations.AddReplayTrackingToDeliveries do
  use Ecto.Migration

  # Manual replay of dead letters (#32): how often a delivery was retried by
  # an operator, by whom and when. `attempts` is reset on replay, so these
  # columns keep the history visible.
  def change do
    alter table(:deliveries) do
      add :retry_count, :integer, null: false, default: 0
      add :retried_by, :string
      add :retried_at, :utc_datetime_usec
    end
  end
end
