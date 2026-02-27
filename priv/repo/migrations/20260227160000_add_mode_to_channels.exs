defmodule Converger.Repo.Migrations.AddModeToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :mode, :text, null: false, default: "duplex"
    end

    # Set outbound for adapter types that only support outbound
    execute "UPDATE channels SET mode = 'outbound' WHERE type IN ('echo', 'websocket')", ""

    create index(:channels, [:mode])
    create index(:channels, [:tenant_id, :mode, :status])
  end
end
