defmodule Converger.Release do
  @moduledoc """
  Release tasks for running migrations in production.

  Usage:
      bin/converger eval "Converger.Release.migrate()"
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
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
