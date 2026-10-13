defmodule Converger.Repo.Migrations.CreateUserSessionsAccountTokensAndTotp do
  @moduledoc """
  Admin / tenant portal auth hardening (issue #52, ADR-0058):

    * `user_sessions` - server-side browser sessions. The cookie only holds a
      random token; its SHA-256 is stored here, so a session can be listed,
      expired and revoked on the server.
    * `account_tokens` - single-use tokens mailed to users (password reset),
      stored as SHA-256 hashes.
    * TOTP two-factor columns on `admin_users` and `tenant_users`; the secret
      is encrypted at rest with `Converger.Vault`.

  `user_id` points to `admin_users` or `tenant_users` depending on
  `user_type`, so it has no foreign key; rows are deleted with the user by
  `Converger.Accounts`.
  """
  use Ecto.Migration

  def change do
    create table(:user_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_type, :string, null: false
      add :user_id, :binary_id, null: false
      add :token_hash, :binary, null: false
      add :ip, :string
      add :user_agent, :string, size: 512
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:user_sessions, [:token_hash])
    create index(:user_sessions, [:user_type, :user_id])
    create index(:user_sessions, [:last_seen_at])
    create index(:user_sessions, [:inserted_at])

    create table(:account_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_type, :string, null: false
      add :user_id, :binary_id, null: false
      add :context, :string, null: false
      add :token_hash, :binary, null: false
      add :sent_to, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:account_tokens, [:context, :token_hash])
    create index(:account_tokens, [:user_type, :user_id])
    create index(:account_tokens, [:inserted_at])

    for table <- [:admin_users, :tenant_users] do
      alter table(table) do
        add :totp_secret, :binary
        add :totp_enabled_at, :utc_datetime_usec
        add :totp_last_step, :bigint
      end
    end
  end
end
