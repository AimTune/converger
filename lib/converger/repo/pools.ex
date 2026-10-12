defmodule Converger.Repo.Pools do
  @moduledoc """
  Two connection pools for one repo: a bulkhead between requests and
  background work (issue #35, ADR-0044, docs/operations/database.md).

    * **interactive** - `Converger.Repo` as configured: HTTP, WebSocket and
      LiveView processes.
    * **background** - a second instance of `Converger.Repo`, registered as
      `Converger.Repo.Background`, used by Oban: its own queries
      (`get_dynamic_repo` in the Oban config) and every job's queries (a
      `[:oban, :job, :start]` telemetry handler, which runs in the job
      process, calls `Converger.Repo.put_dynamic_repo/1`).

  A burst of jobs then waits on its own pool instead of taking the
  connections requests need, and the background pool can queue longer
  (`queue_target`, `queue_interval` and `timeout` per pool).

  `config :converger, Converger.Repo.Pools, background: false` (the test
  default, and `BACKGROUND_POOL_SIZE=0` in production) keeps one shared pool.
  The background instance takes the repo config (URL, SSL, ...) with these
  overrides: `background: [pool_size: 10, queue_target: 500, ...]`.

  Processes a job spawns (`Task.async/1`, ...) do not inherit the dynamic
  repo and use the interactive pool, as does the Broadway pipeline backend.
  """

  alias Converger.Repo

  @background Converger.Repo.Background
  @defaults [queue_target: 500, queue_interval: 5_000, timeout: 60_000]
  @handler_id {__MODULE__, :oban_job_start}

  @doc "Whether the background pool is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: config() != false

  @doc "The repo name background work uses: the background pool, or `Converger.Repo`."
  @spec background() :: atom()
  def background, do: if(enabled?(), do: @background, else: Repo)

  @doc "The background pool's child spec, or none when it is disabled."
  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    case config() do
      false ->
        []

      opts ->
        opts =
          @defaults
          |> Keyword.merge(opts)
          |> Keyword.merge(name: @background, telemetry_prefix: [:converger, :background_repo])

        [%{id: @background, start: {Repo, :start_link, [opts]}, type: :supervisor}]
    end
  end

  @doc "`oban_config` with Oban's own queries routed to the background pool."
  @spec oban_config(keyword()) :: keyword()
  def oban_config(oban_config) do
    if enabled?(),
      do: Keyword.put(oban_config, :get_dynamic_repo, {__MODULE__, :background, []}),
      else: oban_config
  end

  @doc "Routes every Oban job's queries to the background pool. Idempotent."
  @spec attach() :: :ok
  def attach do
    if enabled?() do
      _ =
        :telemetry.attach(@handler_id, [:oban, :job, :start], &__MODULE__.handle_job_start/4, nil)
    end

    :ok
  end

  @doc false
  def handle_job_start(_event, _measurements, _metadata, _config), do: use_background()

  @doc "Makes the calling process use the background pool (no-op when disabled)."
  @spec use_background() :: :ok
  def use_background do
    if enabled?(), do: Repo.put_dynamic_repo(@background)
    :ok
  end

  defp config do
    case Application.get_env(:converger, __MODULE__, [])[:background] do
      opts when is_list(opts) -> opts
      _ -> false
    end
  end
end
