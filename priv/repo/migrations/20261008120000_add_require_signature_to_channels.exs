defmodule Converger.Repo.Migrations.AddRequireSignatureToChannels do
  use Ecto.Migration

  # Existing channels are backfilled with `false` so that integrations which
  # never signed their inbound webhooks keep working (unsigned requests are
  # accepted with a deprecation warning). New channels default to `true`.
  def up do
    alter table(:channels) do
      add :require_signature, :boolean, null: false, default: false
    end

    execute "ALTER TABLE channels ALTER COLUMN require_signature SET DEFAULT true"
  end

  def down do
    alter table(:channels) do
      remove :require_signature
    end
  end
end
