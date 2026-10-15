defmodule Converger.Repo.Migrations.AddPublishableKeyIndexToChannels do
  use Ecto.Migration

  # Publishable keys are looked up on every POST /tokens/publishable
  # (ADR-0074). Built concurrently so the channels table stays writable.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists unique_index(:channels, [:publishable_key],
                           where: "publishable_key IS NOT NULL",
                           concurrently: true
                         )
  end
end
