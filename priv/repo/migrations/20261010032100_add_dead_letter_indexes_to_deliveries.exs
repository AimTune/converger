defmodule Converger.Repo.Migrations.AddDeadLetterIndexesToDeliveries do
  use Ecto.Migration

  # The dead-letter views and `GET /api/v1/deliveries` list deliveries by
  # status (and usually channel), most recently changed first, keyset on
  # (updated_at, id). Built concurrently so the table stays writable.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists index(:deliveries, [:status, :updated_at, :id], concurrently: true)

    create_if_not_exists index(:deliveries, [:channel_id, :status, :updated_at, :id],
                           concurrently: true
                         )
  end
end
