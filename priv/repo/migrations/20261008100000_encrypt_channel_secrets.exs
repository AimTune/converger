defmodule Converger.Repo.Migrations.EncryptChannelSecrets do
  @moduledoc """
  Encrypts `channels.secret` and `channels.config` at rest (issue #12).

  Existing plaintext values are encrypted in place with the key configured
  for `Converger.Vault` (`CLOAK_KEY` in production). Encryption uses
  `Converger.Vault.encrypt_offline!/1`, which does not need the vault
  process, so this works from `Converger.Release.migrate/0` where the
  application is loaded but not started.

  A SHA-256 digest of the secret is stored in `secret_hash` for lookups.
  """
  use Ecto.Migration

  def up do
    alter table(:channels) do
      add :encrypted_secret, :binary
      add :encrypted_config, :binary
      add :secret_hash, :binary
    end

    flush()

    %{rows: rows} = repo().query!("SELECT id, secret, config FROM channels", [], log: false)

    Enum.each(rows, fn [id, secret, config] ->
      repo().query!(
        "UPDATE channels SET encrypted_secret = $1, encrypted_config = $2, secret_hash = $3 WHERE id = $4",
        [
          Converger.Vault.encrypt_offline!(secret),
          Converger.Vault.encrypt_offline!(Jason.encode!(config || %{})),
          :crypto.hash(:sha256, secret),
          id
        ],
        log: false
      )
    end)

    alter table(:channels) do
      remove :secret
      remove :config
    end

    rename table(:channels), :encrypted_secret, to: :secret
    rename table(:channels), :encrypted_config, to: :config

    execute "ALTER TABLE channels ALTER COLUMN secret SET NOT NULL"
    execute "ALTER TABLE channels ALTER COLUMN secret_hash SET NOT NULL"

    create unique_index(:channels, [:secret_hash])
  end

  def down do
    drop_if_exists unique_index(:channels, [:secret_hash])

    alter table(:channels) do
      add :plain_secret, :text
      add :plain_config, :map, default: %{}
    end

    flush()

    %{rows: rows} = repo().query!("SELECT id, secret, config FROM channels", [], log: false)

    Enum.each(rows, fn [id, secret, config] ->
      plain_config =
        if config, do: config |> Converger.Vault.decrypt_offline!() |> Jason.decode!(), else: %{}

      repo().query!(
        "UPDATE channels SET plain_secret = $1, plain_config = $2 WHERE id = $3",
        [Converger.Vault.decrypt_offline!(secret), plain_config, id],
        log: false
      )
    end)

    alter table(:channels) do
      remove :secret
      remove :config
      remove :secret_hash
    end

    rename table(:channels), :plain_secret, to: :secret
    rename table(:channels), :plain_config, to: :config

    execute "ALTER TABLE channels ALTER COLUMN secret SET NOT NULL"
  end
end
