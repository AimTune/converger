defmodule Converger.Repo.Migrations.AddAlertWebhookUrlToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :alert_webhook_url, :string
    end
  end
end
