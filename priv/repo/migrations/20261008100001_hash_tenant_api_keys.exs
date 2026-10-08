defmodule Converger.Repo.Migrations.HashTenantApiKeys do
  @moduledoc """
  Replaces plaintext `tenants.api_key` with a SHA-256 digest (issue #12).

  Existing keys keep working: the digest of the existing value is stored, and
  authentication hashes the presented key. Only the first 4 characters are
  kept (`api_key_prefix`) to help identify a key in the UI.

  This migration is irreversible: plaintext keys cannot be recovered.
  """
  use Ecto.Migration

  def up do
    alter table(:tenants) do
      add :api_key_hash, :binary
      add :api_key_prefix, :text
      add :previous_api_key_hash, :binary
      add :previous_api_key_expires_at, :utc_datetime_usec
    end

    flush()

    # sha256() is built into PostgreSQL 11+.
    execute """
    UPDATE tenants
    SET api_key_hash = sha256(convert_to(api_key, 'UTF8')),
        api_key_prefix = left(api_key, 4)
    """

    execute "ALTER TABLE tenants ALTER COLUMN api_key_hash SET NOT NULL"

    drop_if_exists unique_index(:tenants, [:api_key])

    alter table(:tenants) do
      remove :api_key
    end

    create unique_index(:tenants, [:api_key_hash])
    create index(:tenants, [:previous_api_key_hash])
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "HashTenantApiKeys is irreversible: tenant API keys are stored as hashes " <>
          "and the plaintext keys cannot be restored"
  end
end
