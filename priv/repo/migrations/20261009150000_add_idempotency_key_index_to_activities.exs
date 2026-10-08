defmodule Converger.Repo.Migrations.AddIdempotencyKeyIndexToActivities do
  use Ecto.Migration

  # Inbound webhooks look up re-delivered provider messages (e.g. a WhatsApp
  # wamid) by idempotency key across the conversations of a channel, before a
  # conversation is resolved. The (conversation_id, idempotency_key) unique
  # index cannot serve a lookup by key alone.
  def change do
    create index(:activities, [:idempotency_key], where: "idempotency_key IS NOT NULL")
  end
end
