defmodule Converger.RateLimit.ClusterSync do
  @moduledoc """
  Replicates rate-limit counters between cluster nodes over `Phoenix.PubSub`.

  Every node keeps its own Hammer ETS counters (`Converger.RateLimit.Local`).
  Local hits are additionally recorded as pending deltas in an ETS table owned
  by this process. Every `:interval_ms` the deltas are drained and broadcast to
  the other nodes as one batch message; receivers add them to their own local
  counters. Because Hammer's fixed windows are aligned to wall-clock time,
  every node maps a hit to the same window; deltas for a window that has
  already ended on the receiving node are dropped.

  Trade-offs (see `docs/deployment.md`):

    * no extra infrastructure (no Redis), and no database write per request;
    * eventually consistent: a burst can exceed the limit by at most what the
      other nodes accept during one sync interval (plus PubSub latency);
    * a node that joins or restarts starts with empty counters for the current
      window and catches up as soon as the other nodes sync;
    * windows depend on node clocks, so keep them NTP-synchronised.
  """

  use GenServer

  @default_interval_ms 100

  @doc """
  Starts a sync process.

  Options:

    * `:name` - registered name of the process and of its pending-delta ETS
      table (required)
    * `:local` - Hammer module that holds this node's counters
      (default `Converger.RateLimit.Local`)
    * `:pubsub` - PubSub server (default `Converger.PubSub`)
    * `:topic` - PubSub topic (default `"converger:rate_limit"`)
    * `:interval_ms` - how often pending deltas are broadcast (default #{@default_interval_ms})
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a local increment so that it is broadcast on the next flush.
  Runs in the caller process (lock-free ETS counter update).
  """
  @spec record(atom(), term(), pos_integer(), non_neg_integer()) :: :ok
  def record(name, key, scale, increment) do
    window = div(System.system_time(:millisecond), scale)
    :ets.update_counter(name, {key, scale, window}, increment, {{key, scale, window}, 0})
    :ok
  end

  @doc "Broadcasts the pending deltas immediately (used by tests)."
  @spec flush(GenServer.server()) :: :ok
  def flush(server), do: GenServer.call(server, :flush)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    state = %{
      table:
        :ets.new(name, [
          :named_table,
          :set,
          :public,
          {:write_concurrency, true},
          {:decentralized_counters, true}
        ]),
      local: Keyword.get(opts, :local, Converger.RateLimit.Local),
      pubsub: Keyword.get(opts, :pubsub, Converger.PubSub),
      topic: Keyword.get(opts, :topic, "converger:rate_limit"),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)
    }

    :ok = Phoenix.PubSub.subscribe(state.pubsub, state.topic)
    schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    do_flush(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info({:rate_limit_sync, entries}, state) do
    now = System.system_time(:millisecond)

    Enum.each(entries, fn {key, scale, window, count} ->
      if div(now, scale) == window do
        state.local.inc(key, scale, count)
      end
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_flush(state) do
    now = System.system_time(:millisecond)

    entries =
      state.table
      |> :ets.tab2list()
      |> Enum.flat_map(fn {{key, scale, window} = pending_key, count} ->
        # Subtract what we read instead of deleting, so concurrent increments
        # recorded between the read and the delete are kept for the next flush.
        :ets.update_counter(state.table, pending_key, -count)

        if count > 0 and div(now, scale) == window,
          do: [{key, scale, window, count}],
          else: []
      end)

    :ets.select_delete(state.table, [{{:_, 0}, [], [true]}])

    if entries != [] do
      Phoenix.PubSub.broadcast_from(
        state.pubsub,
        self(),
        state.topic,
        {:rate_limit_sync, entries}
      )
    end

    :ok
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :flush, interval_ms)
end
