defmodule Converger.Repo.Migrations.AddTypeToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :type, :string, default: "standart", null: false
    end
  end
end
