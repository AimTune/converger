defmodule Converger.Repo.Migrations.AddPublishableKeyToChannels do
  @moduledoc """
  Publishable keys (issue #195, ADR-0074): a browser-safe channel credential
  that mints anonymous, conversation-bound client tokens, and the origins
  allowed to use it. Both columns are nullable or have a constant default,
  so the change is rolling-deploy safe (expand).
  """
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :publishable_key, :text
      add :allowed_origins, {:array, :text}, null: false, default: []
    end
  end
end
