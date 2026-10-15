defmodule Converger.Repo.Migrations.AddConditionsToRoutingRules do
  use Ecto.Migration

  # Conditional routing rules (#43, ADR-0046): predicates over the activity,
  # per-rule middleware, and first-match ordering. Every column has a
  # constant default, so existing rules keep their behaviour (no condition
  # matches everything, no transformations, same priority, no stop) and the
  # ALTER is metadata-only.
  def change do
    alter table(:routing_rules) do
      add :conditions, :jsonb, null: false, default: "{}"
      add :transformations, :jsonb, null: false, default: "[]"
      add :priority, :integer, null: false, default: 100
      add :stop_processing, :boolean, null: false, default: false
    end

    # Rules are read per source channel in priority order.
    create index(:routing_rules, [:source_channel_id, :priority])
  end
end
