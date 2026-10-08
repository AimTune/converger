defmodule Converger.Release do
  @moduledoc """
  Release tasks, run with `bin/converger eval` (no Mix in releases).

      bin/migrate                                          # create_db (if CREATE_DB=true) + migrate
      bin/converger eval "Converger.Release.migrate()"
      bin/converger eval "Converger.Release.seed_admin()"

  Migrations must run as a separate deploy step, not from every replica's
  start command. `migrate/0` is still safe to run concurrently: the repo is
  configured with `migration_lock: :pg_advisory_lock`, so a second runner
  waits for the first one and then finds no pending migrations. See
  docs/deployment.md.
  """

  @app :converger

  def create_db do
    load_app()

    for repo <- repos() do
      case repo.__adapter__().storage_up(repo.config()) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, term} -> {:error, term}
      end
    end
  end

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &run_migrations/1)
    end
  end

  # Ecto creates `schema_migrations` (CREATE TABLE IF NOT EXISTS) before it
  # takes the migration lock, so two runners racing on a brand-new database
  # can collide on that statement. The loser retries once; by then the table
  # exists and it simply waits for the lock.
  defp run_migrations(repo, attempt \\ 1) do
    Ecto.Migrator.run(repo, :up, all: true)
  rescue
    error in Postgrex.Error ->
      if attempt == 1 and error.postgres[:code] in [:unique_violation, :duplicate_table] do
        run_migrations(repo, attempt + 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Re-encrypts all secrets at rest with the current default `CLOAK_KEY`.
  Run after rotating the key (old key moved to `CLOAK_RETIRED_KEYS`):

      bin/converger eval "Converger.Release.reencrypt_secrets()"
  """
  def reencrypt_secrets do
    load_app()

    {:ok, count, _} =
      Ecto.Migrator.with_repo(Converger.Repo, fn _repo ->
        {:ok, _} = Application.ensure_all_started(:cloak)
        start_vault()
        Converger.Channels.reencrypt_all()
      end)

    IO.puts("Re-encrypted #{count} channel(s)")
    count
  end

  defp start_vault do
    case Converger.Vault.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Creates the initial `super_admin` when no admin user exists yet.

  Reads `ADMIN_EMAIL` (default `admin@converger.local`) and `ADMIN_PASSWORD`.
  Without `ADMIN_PASSWORD` a random password is generated and printed once;
  the account is then flagged `must_change_password` so the first login has
  to replace it. See `Converger.Accounts.bootstrap_super_admin/1`.
  """
  def seed_admin do
    load_app()
    {:ok, _} = Application.ensure_all_started(:bcrypt_elixir)

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Converger.Repo, fn _repo ->
        result =
          Converger.Accounts.bootstrap_super_admin(
            email: System.get_env("ADMIN_EMAIL"),
            password: System.get_env("ADMIN_PASSWORD")
          )

        report_seed_admin(result)
        result
      end)

    result
  end

  @doc false
  def report_seed_admin({:ok, user, :generated, password}) do
    IO.puts("""
    Created super_admin #{user.email}
    Generated one-time password (shown only once, change it at first login):

        #{password}
    """)
  end

  def report_seed_admin({:ok, user, :provided, _password}),
    do: IO.puts("Created super_admin #{user.email} with the password from ADMIN_PASSWORD")

  def report_seed_admin(:exists),
    do: IO.puts("Admin users already exist; nothing to seed")

  def report_seed_admin({:error, changeset}),
    do: IO.puts("Failed to create super_admin: #{inspect(changeset.errors)}")

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
