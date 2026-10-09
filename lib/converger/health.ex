defmodule Converger.Health do
  @moduledoc """
  Liveness and readiness checks behind `GET /health/live` and
  `GET /health/ready` (`ConvergerWeb.Plugs.Health`).

  * **Liveness** only says that the VM is up and the endpoint answers; it
    never touches the database, so a database outage does not make an
    orchestrator restart every replica.
  * **Readiness** says whether this node should receive traffic. It runs
    these checks, each of them cheap:

    | Check        | Not ready when                                                     |
    | ------------ | ------------------------------------------------------------------ |
    | `database`   | `SELECT 1` fails or takes longer than `:db_timeout_ms` (1 s)       |
    | `oban`       | the Oban supervisor is not running                                 |
    | `draining`   | the node is shutting down (`ConvergerWeb.Drain`)                   |
    | `migrations` | a migration shipped with this release is not applied yet           |

  ## Draining

  The draining state has one source of truth, `ConvergerWeb.Drain`
  (ADR-0027, WebSocket limits and draining; ADR-0036): on shutdown it flips
  `ConvergerWeb.Drain.draining?/0`, which this check reads, and waits
  `drain_delay_ms` (`WS_DRAIN_DELAY_MS`) before the endpoint drains its
  sockets. Readiness then fails with `draining`.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Converger.Repo

  @migrations_key {__MODULE__, :migrations_applied}
  @default_db_timeout_ms 1_000

  @type check :: :database | :oban | :draining | :migrations
  @type result :: :ok | {:error, String.t()}

  @doc "Readiness: `{:ok, checks}` or `{:error, checks}` with a result per check."
  @spec readiness() :: {:ok | :error, [{check(), result()}]}
  def readiness do
    database = check_database()

    checks = [
      database: database,
      oban: check_oban(),
      draining: check_draining(),
      # Needs the database; reported as failing with the database.
      migrations:
        if(database == :ok, do: check_migrations(), else: {:error, "migrations unknown"})
    ]

    status = if Enum.all?(checks, fn {_check, result} -> result == :ok end), do: :ok, else: :error
    {status, checks}
  end

  @doc false
  @spec check_database() :: result()
  def check_database do
    case Repo.query("SELECT 1", [], timeout: db_timeout_ms(), log: false) do
      {:ok, _} -> :ok
      {:error, error} -> unavailable("database unavailable", error)
    end
  rescue
    error -> unavailable("database unavailable", error)
  catch
    :exit, reason -> unavailable("database unavailable", reason)
  end

  @doc false
  @spec check_oban() :: result()
  def check_oban do
    case Oban.whereis(Oban) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: {:error, "oban not running"}

      _ ->
        {:error, "oban not running"}
    end
  end

  @doc false
  @spec check_draining() :: result()
  def check_draining,
    do: if(ConvergerWeb.Drain.draining?(), do: {:error, "draining"}, else: :ok)

  @doc """
  Compares the migrations shipped with the release with `schema_migrations`.
  Once everything is applied the result is cached, so later probes skip the
  query. Reads the table directly instead of using `Ecto.Migrator`, which
  would wait for the migration advisory lock while `bin/migrate` runs.
  """
  @spec check_migrations() :: result()
  def check_migrations do
    if :persistent_term.get(@migrations_key, false) do
      :ok
    else
      do_check_migrations()
    end
  end

  defp do_check_migrations do
    applied =
      Repo.all(from(m in "schema_migrations", select: m.version),
        timeout: db_timeout_ms(),
        log: false
      )
      |> MapSet.new()

    case Enum.reject(release_migrations(), &MapSet.member?(applied, &1)) do
      [] ->
        :persistent_term.put(@migrations_key, true)
        :ok

      pending ->
        {:error, "migrations pending: #{length(pending)}"}
    end
  rescue
    error -> unavailable("migrations unknown", error)
  catch
    :exit, reason -> unavailable("migrations unknown", reason)
  end

  @doc false
  # Clears the cached "all migrations applied" result (tests).
  def reset_migrations_cache, do: :persistent_term.erase(@migrations_key)

  @doc "Versions of the migration files shipped with this release."
  @spec release_migrations() :: [integer()]
  def release_migrations do
    Repo
    |> Ecto.Migrator.migrations_path()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Integer.parse(Path.basename(path)) do
        {version, "_" <> _} -> [version]
        _ -> []
      end
    end)
  end

  # The probe response is unauthenticated: it carries a short reason only,
  # the details (which may name hosts) go to the log.
  defp unavailable(reason, detail) do
    detail = if is_exception(detail), do: Exception.message(detail), else: inspect(detail)
    Logger.warning("Readiness check failed: #{reason}: #{detail}")
    {:error, reason}
  end

  defp db_timeout_ms do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:db_timeout_ms, @default_db_timeout_ms)
  end
end
