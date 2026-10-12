defmodule Converger.Repo.Migrations.CreateWebhookSubscriptionsAndEvents do
  @moduledoc """
  Platform event webhooks (issue #49, ADR-0053): tenant-level subscriptions
  (`webhook_subscriptions`) and the per-subscription event log
  (`webhook_events`, pruned after 7 days by `Converger.Retention.prune/1`).

  `secret` and `headers` are encrypted at rest with `Converger.Vault`, like
  `channels.secret` and `channels.config`.
  """
  use Ecto.Migration

  def change do
    create table(:webhook_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :url, :text, null: false
      add :description, :string
      add :secret, :binary, null: false
      add :events, {:array, :string}, null: false, default: []
      add :enabled, :boolean, null: false, default: true
      add :headers, :binary
      # Set for subscriptions maintained by the platform (e.g.
      # "alert_webhook_url" for the legacy tenant health alert URL).
      add :managed_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhook_subscriptions, [:tenant_id])

    create unique_index(:webhook_subscriptions, [:tenant_id, :managed_by],
             where: "managed_by IS NOT NULL",
             name: :webhook_subscriptions_tenant_managed_by_index
           )

    create table(:webhook_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :subscription_id,
          references(:webhook_subscriptions, type: :binary_id, on_delete: :delete_all),
          null: false

      # Id of the occurrence, shared by every subscription that receives it.
      add :event_id, :binary_id, null: false
      add :type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :response_status, :integer
      add :delivered_at, :utc_datetime_usec
      add :redelivered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhook_events, [:subscription_id, :inserted_at])
    create index(:webhook_events, [:tenant_id, :inserted_at])
    create index(:webhook_events, [:inserted_at])
  end
end
