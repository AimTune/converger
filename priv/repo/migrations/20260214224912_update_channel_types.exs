defmodule Converger.Repo.Migrations.UpdateChannelTypes do
  use Ecto.Migration

  def change do
    execute "UPDATE channels SET type = 'webhook' WHERE type = 'standard'"

    alter table(:channels) do
      modify :type, :string, default: "webhook", null: false
    end
  end
end
