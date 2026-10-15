defmodule ConvergerWeb.Protocol.Admission do
  @moduledoc """
  Per-node admission queue for the database work of Protocol v1 handshakes
  and replays (issue #198, ADR-0077).

  When a node drains, its clients reconnect to the other nodes within a few
  seconds. Each `hello` reads the channel, the conversation, its head, the
  open interrupts and the replay. Without a bound, thousands of those reach
  the interactive pool at once: checkouts queue past `queue_target`, the
  pool drops them (`DBConnection.ConnectionError`), the clients are told
  `unavailable` / `replay_unavailable` and back off, and their backoff
  stretches the reconnect tail far beyond the outage.

  `run/1` runs the work once one of `handshake_concurrency` slots is free,
  so a burst waits here, first come first served, instead of in the pool's
  queue, and the rest of the pool stays free for REST and live traffic. A
  caller that waits longer than `handshake_queue_ms`, or finds
  `handshake_queue_max` callers already waiting, gets `{:error, :overloaded}`
  and is answered with the same retryable errors as before (#35). A database
  that is really down still fails inside the work and is reported as before.

  Configured in `config :converger, :websocket` (`WS_HANDSHAKE_*`,
  docs/operations/websocket-limits.md). `handshake_concurrency: 0`, the
  default, uses half the interactive pool (`POOL_SIZE`), at least 1.

  A slot belongs to the calling process: it is released when the work
  returns or raises, and when the caller exits while holding or waiting for
  one.
  """

  use GenServer

  alias Converger.Repo

  @doc """
  Runs `fun` in the calling process once a slot is free. Returns
  `{:ok, result}`, or `{:error, :overloaded}` when no slot became free in
  time. Exceptions of `fun` propagate after the slot is released.

  Emits `[:converger, :protocol, :admission]` with `wait_ms`, and `result`
  (`:ok` or `:overloaded`) in the metadata.
  """
  @spec run((-> result)) :: {:ok, result} | {:error, :overloaded} when result: term()
  def run(fun) when is_function(fun, 0) do
    started = System.monotonic_time()

    case acquire() do
      {:ok, ref} ->
        emit(started, :ok)

        try do
          {:ok, fun.()}
        after
          release(ref)
        end

      {:error, :overloaded} = error ->
        emit(started, :overloaded)
        error
    end
  end

  @doc "Slots in use, callers waiting and the slot limit."
  @spec stats() :: %{active: non_neg_integer(), waiting: non_neg_integer(), limit: pos_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "The number of slots: `handshake_concurrency`, or half the interactive pool (at least 1)."
  @spec limit() :: pos_integer()
  def limit do
    case config(:handshake_concurrency) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        pool_size = Application.get_env(:converger, Repo, [])[:pool_size] || 10
        max(div(pool_size, 2), 1)
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # The server answers when a slot is free or the wait expired, so the call
  # itself never times out.
  defp acquire do
    GenServer.call(__MODULE__, {:acquire, self()}, :infinity)
  catch
    # No admission server (restarting, or the node is shutting down): answer
    # as overloaded rather than crash the connection.
    :exit, _reason -> {:error, :overloaded}
  end

  defp release(ref), do: GenServer.cast(__MODULE__, {:release, ref})

  defp emit(started, result) do
    wait_us = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

    :telemetry.execute(
      [:converger, :protocol, :admission],
      %{wait_ms: wait_us / 1_000},
      %{result: result}
    )
  end

  ## Server

  @impl true
  def init(_opts) do
    # active: monitor ref => pid of each slot holder. queue: refs of waiters
    # in arrival order. waiting: ref => {from, timer} of the callers still
    # waiting; a ref that expired or whose caller exited is only removed
    # from `waiting` and skipped when it reaches the head of the queue.
    {:ok, %{active: %{}, queue: :queue.new(), waiting: %{}}}
  end

  @impl true
  def handle_call({:acquire, pid}, from, state) do
    ref = Process.monitor(pid)

    cond do
      map_size(state.active) < limit() and map_size(state.waiting) == 0 ->
        {:reply, {:ok, ref}, %{state | active: Map.put(state.active, ref, pid)}}

      map_size(state.waiting) >= config(:handshake_queue_max) ->
        Process.demonitor(ref, [:flush])
        {:reply, {:error, :overloaded}, state}

      true ->
        timer = Process.send_after(self(), {:expire, ref}, config(:handshake_queue_ms))

        {:noreply,
         %{
           state
           | queue: :queue.in(ref, state.queue),
             waiting: Map.put(state.waiting, ref, {from, timer})
         }}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{active: map_size(state.active), waiting: map_size(state.waiting), limit: limit()},
     state}
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, grant(%{state | active: Map.delete(state.active, ref)})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # A holder that exited frees its slot; a waiter that exited leaves.
    waiting =
      case Map.pop(state.waiting, ref) do
        {nil, waiting} ->
          waiting

        {{_from, timer}, waiting} ->
          Process.cancel_timer(timer)
          waiting
      end

    {:noreply, grant(%{state | active: Map.delete(state.active, ref), waiting: waiting})}
  end

  def handle_info({:expire, ref}, state) do
    case Map.pop(state.waiting, ref) do
      {nil, _waiting} ->
        {:noreply, state}

      {{from, _timer}, waiting} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, {:error, :overloaded})
        {:noreply, %{state | waiting: waiting}}
    end
  end

  # Hand free slots to the oldest callers still waiting.
  defp grant(state) do
    with true <- map_size(state.active) < limit(),
         {{:value, ref}, queue} <- :queue.out(state.queue) do
      state = %{state | queue: queue}

      case Map.pop(state.waiting, ref) do
        {nil, _waiting} ->
          grant(state)

        {{{pid, _tag} = from, timer}, waiting} ->
          Process.cancel_timer(timer)
          GenServer.reply(from, {:ok, ref})
          grant(%{state | waiting: waiting, active: Map.put(state.active, ref, pid)})
      end
    else
      _ -> state
    end
  end

  defp config(key), do: Application.fetch_env!(:converger, :websocket)[key]
end
