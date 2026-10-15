defmodule Converger.Repo.Migrations.AddCircuitBreakerRateLimitAndTenantTier do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      # Delivery circuit breaker (Converger.Channels.Circuit):
      # closed | open | half_open | paused (manual).
      add :circuit_state, :string, null: false, default: "closed"
      add :circuit_changed_at, :utc_datetime_usec
      add :consecutive_failures, :integer, null: false, default: 0
      # Outbound rate limit, e.g. "80/s"; NULL uses the adapter default (if any).
      add :rate_limit, :string
    end

    alter table(:tenants) do
      # Delivery queue tier: high | default | bulk.
      add :tier, :string, null: false, default: "default"
    end
  end
end
