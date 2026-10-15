defmodule Converger.Repo.Migrations.AddChannelActivityIndexToConversations do
  use Ecto.Migration

  # The client API's conversation list for channel-scoped tokens (agent
  # consoles, ADR-0065) is keyset-paginated on (updated_at, id) within one
  # channel, most recently active first. This index makes each page an index
  # range scan. Built concurrently so the table stays writable.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists index(:conversations, [:channel_id, :updated_at, :id],
                           concurrently: true
                         )
  end
end
