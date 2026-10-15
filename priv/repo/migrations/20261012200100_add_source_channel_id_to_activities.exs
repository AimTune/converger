defmodule Converger.Repo.Migrations.AddSourceChannelIdToActivities do
  use Ecto.Migration

  # Reply-back routing (#43, ADR-0046): the channel an activity came in on.
  # Nil for activities written without a channel (tenant API, system events)
  # and for every activity stored before this migration; the pipeline treats
  # nil like the conversation's own channel, which is how all activities
  # were routed before.
  #
  # `activities` is partitioned by month (ADR-0034): a nullable column without
  # a default is metadata-only on the parent and every partition. No foreign
  # key (partitioned tables have none, ADR-0034) and no index (it is never
  # searched).
  def up do
    execute "SET LOCAL lock_timeout = '5s'"
    execute "ALTER TABLE activities ADD COLUMN IF NOT EXISTS source_channel_id uuid"
  end

  def down do
    execute "ALTER TABLE activities DROP COLUMN IF EXISTS source_channel_id"
  end
end
