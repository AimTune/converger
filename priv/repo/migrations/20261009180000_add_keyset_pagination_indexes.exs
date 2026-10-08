defmodule Converger.Repo.Migrations.AddKeysetPaginationIndexes do
  use Ecto.Migration

  # Keyset pagination (Converger.Pagination.keyset/2) orders by
  # (inserted_at, id) and seeks with `(inserted_at, id) < (cursor)`. These
  # composite indexes let each page be an index range scan, with or without
  # the common tenant filter. Built concurrently so large tables stay writable.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists index(:conversations, [:inserted_at, :id], concurrently: true)

    create_if_not_exists index(:conversations, [:tenant_id, :inserted_at, :id],
                           concurrently: true
                         )

    create_if_not_exists index(:audit_logs, [:inserted_at, :id], concurrently: true)
    create_if_not_exists index(:tenant_users, [:inserted_at, :id], concurrently: true)
    create_if_not_exists index(:deliveries, [:inserted_at, :id], concurrently: true)
  end
end
