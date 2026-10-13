defmodule Converger.Repo.Migrations.CreateRevokedTokens do
  @moduledoc """
  Converger token revocations (issue #52, ADR-0057): one row per revoked
  token family, rotated token (`jti`) or revoked end user. Rows are only
  needed until every token they can match has expired (`expires_at`), and are
  then deleted by `Converger.Retention.prune/1`. Each node keeps them in an
  ETS cache (`Converger.Auth.RevocationCache`).
  """
  use Ecto.Migration

  def change do
    create table(:revoked_tokens, primary_key: false) do
      # "fam:<family>", "jti:<jti>" or "user:<channel_id>:<user_id>"
      add :key, :text, primary_key: true
      # "revoked" or "rotated"
      add :kind, :string, null: false
      add :tenant_id, :binary_id
      add :revoked_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:revoked_tokens, [:expires_at])
  end
end
