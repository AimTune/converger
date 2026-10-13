defmodule Converger.Repo.Migrations.CreateApiKeys do
  @moduledoc """
  Scoped tenant API keys (issue #51, ADR-0061).

  A tenant keeps its primary key (`tenants.api_key_hash`, every scope); keys
  in `api_keys` carry a subset of `read`, `write` and `manage`, can expire
  and are revoked rather than deleted, so the audit log's `actor_id` (the
  key id) always resolves. Only the key's SHA-256 is stored.
  """
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :key_hash, :binary, null: false
      add :prefix, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :created_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:tenant_id])
  end
end
