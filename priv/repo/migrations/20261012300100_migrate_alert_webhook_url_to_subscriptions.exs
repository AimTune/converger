defmodule Converger.Repo.Migrations.MigrateAlertWebhookUrlToSubscriptions do
  @moduledoc """
  Moves every `tenants.alert_webhook_url` to a platform webhook subscription
  (issue #49) on `channel.health_changed`, `channel.circuit_opened` and
  `channel.circuit_closed`, marked `managed_by = 'alert_webhook_url'`. The
  subscription keeps the legacy JSON body, so existing receivers keep
  working; requests are now also signed with a generated secret.

  The column stays: setting it in the admin tenant form keeps the managed
  subscription in sync (`Converger.Webhooks.sync_alert_subscription/1`).
  Secrets are encrypted with `Converger.Vault.encrypt_offline!/1` (no vault
  process needed, works from `Converger.Release.migrate/0`).
  """
  use Ecto.Migration

  @events ["channel.health_changed", "channel.circuit_opened", "channel.circuit_closed"]

  def up do
    %{rows: rows} =
      repo().query!(
        "SELECT id, alert_webhook_url FROM tenants " <>
          "WHERE alert_webhook_url IS NOT NULL AND alert_webhook_url <> ''",
        [],
        log: false
      )

    now = DateTime.utc_now()

    Enum.each(rows, fn [tenant_id, url] ->
      secret = "whsec_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      repo().query!(
        """
        INSERT INTO webhook_subscriptions
          (id, tenant_id, url, description, secret, events, enabled, managed_by, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, true, 'alert_webhook_url', $7, $7)
        ON CONFLICT DO NOTHING
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          tenant_id,
          url,
          "Channel health alerts (tenants.alert_webhook_url)",
          Converger.Vault.encrypt_offline!(secret),
          @events,
          now
        ],
        log: false
      )
    end)
  end

  def down do
    execute "DELETE FROM webhook_subscriptions WHERE managed_by = 'alert_webhook_url'"
  end
end
