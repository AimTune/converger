defmodule Converger.Repo.Migrations.AddTransformationsToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :transformations, :jsonb, default: "[]", null: false
    end
  end
end
