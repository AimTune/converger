defmodule Converger.ReleaseMigrationLockTest do
  @moduledoc """
  Simulates a rolling deploy where two replicas (or init containers) run
  migrations at the same moment, and checks that the repo's advisory-lock
  migration strategy applies each migration exactly once.

  Runs outside the SQL sandbox on a separate, unpooled repo instance and
  keeps everything (including its schema_migrations table) in a throwaway
  Postgres schema.
  """
  use ExUnit.Case, async: false

  alias Converger.Repo

  @prefix "migration_lock_test"

  defmodule SlowMigration do
    use Ecto.Migration

    def up do
      # Keep the lock long enough for the second runner to contend for it.
      Process.sleep(300)
      execute("INSERT INTO #{prefix()}.migration_runs (ran_at) VALUES (now())")
    end

    def down, do: :ok
  end

  setup do
    repo = start_repo()

    query!(repo, "DROP SCHEMA IF EXISTS #{@prefix} CASCADE")
    query!(repo, "CREATE SCHEMA #{@prefix}")
    query!(repo, "CREATE TABLE #{@prefix}.migration_runs (ran_at timestamptz NOT NULL)")

    # The test's repo dies with the test process, so clean up with a new one.
    on_exit(fn ->
      cleanup = start_repo()
      query!(cleanup, "DROP SCHEMA IF EXISTS #{@prefix} CASCADE")
      Supervisor.stop(cleanup)
    end)

    %{repo: repo}
  end

  defp start_repo do
    {:ok, repo} =
      Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 4, log: false)

    repo
  end

  defp query!(repo, sql) do
    previous = Repo.put_dynamic_repo(repo)

    try do
      Repo.query!(sql)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  test "the repo uses the advisory lock migration strategy" do
    assert Repo.config()[:migration_lock] == :pg_advisory_lock
  end

  test "concurrent migration runs apply each migration exactly once", %{repo: repo} do
    # Bootstrap schema_migrations first, as on any database that has been
    # migrated before. (Ecto creates that table before taking the lock, so
    # two runners racing on a brand-new database can collide on its CREATE.)
    assert [] =
             Ecto.Migrator.run(Repo, [], :up,
               all: true,
               prefix: @prefix,
               dynamic_repo: repo,
               log: false
             )

    run = fn ->
      Ecto.Migrator.run(Repo, [{20_990_101_000_000, SlowMigration}], :up,
        all: true,
        prefix: @prefix,
        dynamic_repo: repo,
        log: false
      )
    end

    results =
      [run, run]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(30_000)

    # Exactly one runner applied the migration; the other found it done.
    assert Enum.sort(results) == [[], [20_990_101_000_000]]

    assert %{rows: [[1]]} = query!(repo, "SELECT count(*) FROM #{@prefix}.migration_runs")
  end
end
