defmodule Converger.Repo.Pressure do
  @moduledoc """
  Graceful degradation under database pressure (issue #35, ADR-0044,
  docs/operations/database.md).

    * **Classifies** the errors that mean "the database is unavailable right
      now": `DBConnection.ConnectionError`, raised when a pool checkout is
      dropped from the queue (`queue_target` / `queue_interval`), when a query
      exceeds `timeout`, or when the connection is lost. Callers answer them
      with a retryable error (HTTP `503` with `Retry-After`, a WebSocket
      `unavailable` / `replay_unavailable` error) instead of crashing.
    * **Reports** them: the `[:converger, :db, :unavailable]` telemetry event
      (`count: 1`, metadata `source`) for every occurrence, and at most one
      warning log per second, so an outage does not flood the logs.
    * **Measures** how long checkouts wait for a connection of the
      interactive pool: the average `queue_time` of `[:converger, :repo,
      :query]` over the last `queue_window_ms`. Readiness
      (`Converger.Health`) reports `degraded` while it is at least
      `degraded_queue_ms`, so load balancers shed load before requests fail.
    Every window ends with `[:converger, :repo, :pool]` (`queue_time_ms`,
    `samples`).

  Configured with `config :converger, Converger.Repo.Pressure` (see
  config/config.exs; `DB_RETRY_AFTER_MS`, `DB_QUEUE_WINDOW_MS` and
  `READY_DB_QUEUE_MS` in production).
  """

  use GenServer

  require Logger

  @refs {__MODULE__, :refs}
  @handler_id {__MODULE__, :repo_query}
  @log_interval_ms 1_000

  ## Errors

  @doc "Whether `error` means the database is unavailable (retry later)."
  @spec unavailable?(term()) :: boolean()
  def unavailable?(%DBConnection.ConnectionError{}), do: true
  def unavailable?(%Plug.Conn.WrapperError{reason: reason}), do: unavailable?(reason)
  def unavailable?(_error), do: false

  @doc """
  The retry hint for clients, in milliseconds: `retry_after_ms` jittered up
  to twice its value, so clients do not come back all at once.
  """
  @spec retry_after_ms() :: pos_integer()
  def retry_after_ms do
    base = max(config(:retry_after_ms), 1)
    base + :rand.uniform(base + 1) - 1
  end

  @doc """
  Records that `source` (`:http`, `:channel`, `:protocol`, ...) could not
  reach the database. Emits `[:converger, :db, :unavailable]` and logs a
  warning, at most one per second.
  """
  @spec report(atom(), Exception.t()) :: :ok
  def report(source, error) do
    :telemetry.execute([:converger, :db, :unavailable], %{count: 1}, %{source: source})

    if log_now?() do
      Logger.warning(
        "Database unavailable (#{source}), answered with a retryable error: " <>
          Exception.message(error) <>
          " (further reports suppressed for #{@log_interval_ms} ms)"
      )
    end

    :ok
  end

  ## Pool wait time

  @doc "Average wait for an interactive pool connection over the last window, in ms."
  @spec queue_time_ms() :: float()
  def queue_time_ms do
    case refs() do
      {_counters, atomics} -> :atomics.get(atomics, 1) / 1_000
      nil -> 0.0
    end
  end

  @doc "Whether the interactive pool's average wait is at or above `degraded_queue_ms`."
  @spec degraded?() :: boolean()
  def degraded? do
    threshold = config(:degraded_queue_ms)
    threshold > 0 and queue_time_ms() >= threshold
  end

  @doc false
  # Closes the current window now (tests).
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc false
  # Records one checkout that waited `microseconds` (tests).
  def record(microseconds) do
    case refs() do
      {counters, _atomics} ->
        :counters.add(counters, 1, microseconds)
        :counters.add(counters, 2, 1)

      nil ->
        :ok
    end
  end

  @doc false
  def handle_query(_event, %{queue_time: queue_time}, _metadata, _config)
      when is_integer(queue_time) do
    record(System.convert_time_unit(queue_time, :native, :microsecond))
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  ## GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # counters: 1 = sum of queue times (µs), 2 = samples in the window.
    # atomics: 1 = average of the last window (µs), 2 = last log (ms).
    counters = :counters.new(2, [:write_concurrency])
    atomics = :atomics.new(2, signed: true)
    :atomics.put(atomics, 2, System.monotonic_time(:millisecond) - @log_interval_ms)
    :persistent_term.put(@refs, {counters, atomics})

    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach(@handler_id, [:converger, :repo, :query], &__MODULE__.handle_query/4, nil)

    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    close_window()
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    close_window()
    {:reply, :ok, state}
  end

  defp close_window do
    {counters, atomics} = refs()
    sum = :counters.get(counters, 1)
    count = :counters.get(counters, 2)
    # Subtract instead of resetting: samples added meanwhile count next time.
    :counters.sub(counters, 1, sum)
    :counters.sub(counters, 2, count)
    average = if count > 0, do: div(sum, count), else: 0
    :atomics.put(atomics, 1, average)

    :telemetry.execute(
      [:converger, :repo, :pool],
      %{queue_time_ms: average / 1_000, samples: count},
      %{}
    )
  end

  defp schedule, do: Process.send_after(self(), :tick, config(:queue_window_ms))

  defp log_now? do
    case refs() do
      {_counters, atomics} ->
        now = System.monotonic_time(:millisecond)
        last = :atomics.get(atomics, 2)
        now - last >= @log_interval_ms and :atomics.compare_exchange(atomics, 2, last, now) == :ok

      nil ->
        true
    end
  end

  defp refs, do: :persistent_term.get(@refs, nil)

  defp config(key), do: Application.fetch_env!(:converger, __MODULE__)[key]
end
