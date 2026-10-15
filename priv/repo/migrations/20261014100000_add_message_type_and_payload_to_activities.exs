defmodule Converger.Repo.Migrations.AddMessageTypeAndPayloadToActivities do
  use Ecto.Migration

  # Typed message payloads (#68, ADR-0062): a `message` activity may carry a
  # Protocol v1 message type (`card`, `buttons`, `tool_call`, ...) and the
  # lossless frame body it was received as. Both nil for plain messages and
  # for every activity stored before this migration.
  #
  # `activities` is partitioned by month (ADR-0034): nullable columns without
  # a default are metadata-only on the parent and every partition. No index:
  # neither column is searched (`text` keeps the denormalised fallback).
  def up do
    execute "SET LOCAL lock_timeout = '5s'"
    execute "ALTER TABLE activities ADD COLUMN IF NOT EXISTS message_type text"
    execute "ALTER TABLE activities ADD COLUMN IF NOT EXISTS payload jsonb"
  end

  def down do
    execute "ALTER TABLE activities DROP COLUMN IF EXISTS payload"
    execute "ALTER TABLE activities DROP COLUMN IF EXISTS message_type"
  end
end
