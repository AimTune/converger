defmodule Converger.Repo.Migrations.AddReceiptTrackingToDeliveries do
  use Ecto.Migration

  def change do
    alter table(:deliveries) do
      add :sent_at, :utc_datetime_usec
      add :read_at, :utc_datetime_usec
      add :provider_message_id, :text
    end

    # Index for looking up deliveries by provider message ID
    # (critical path: status webhook arrives with only the provider ID)
    create index(:deliveries, [:provider_message_id], where: "provider_message_id IS NOT NULL")

    # Scoped lookup by channel + provider message ID
    create index(:deliveries, [:channel_id, :provider_message_id],
             where: "provider_message_id IS NOT NULL"
           )

    # Data migration:
    # 1. "delivered" → "sent" (adapter success = message left our system)
    # 2. Copy delivered_at → sent_at for renamed rows
    # 3. Backfill provider_message_id from metadata JSON
    execute(
      """
      UPDATE deliveries
      SET sent_at = delivered_at,
          status = CASE
            WHEN status = 'delivered' THEN 'sent'
            ELSE status
          END,
          provider_message_id = COALESCE(
            metadata->>'whatsapp_message_id',
            metadata->>'infobip_message_id'
          )
      """,
      """
      UPDATE deliveries
      SET status = CASE
            WHEN status = 'sent' THEN 'delivered'
            WHEN status IN ('delivered', 'read') THEN 'delivered'
            ELSE status
          END,
          delivered_at = COALESCE(delivered_at, sent_at)
      """
    )
  end
end
