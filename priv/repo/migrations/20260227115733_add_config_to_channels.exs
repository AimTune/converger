defmodule Converger.Repo.Migrations.AddConfigToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :config, :map, default: %{}
    end
  end
end
