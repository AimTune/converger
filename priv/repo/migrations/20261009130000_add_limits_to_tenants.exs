defmodule Converger.Repo.Migrations.AddLimitsToTenants do
  use Ecto.Migration

  # Per-tenant rate-limit overrides, e.g.
  # %{"activity_create" => %{"limit" => 200, "scale_ms" => 1000}}.
  # An empty map means the configured defaults apply.
  def change do
    alter table(:tenants) do
      add :limits, :map, null: false, default: %{}
    end
  end
end
