defmodule Converger.Repo.Migrations.AddRetryPolicyToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :retry_policy, :map, null: false, default: %{}
    end
  end
end
