defmodule Converger.Channels.InFlight do
  @moduledoc """
  Per-node cap on the deliveries of one channel that run at the same time
  (ADR-0076).

  Before its breaker opens, a dead channel's backlog would take every worker of
  its tier queue, each waiting one adapter timeout, and the queue would run
  nothing else (#191). `acquire/2` gives a delivery job a slot of its channel
  only while fewer than `cap` are taken on this node; a job over the cap is
  snoozed by the worker and does not touch the database.

  Slots are held by the job process and released by `release/1`, or when the
  process exits (the server monitors it), so a killed job cannot leak a slot.

  `acquire/2` also tells the caller, at most once per `defer_ms` and channel,
  that it should defer the channel's waiting backlog
  (`Converger.Channels.Circuit.defer_backlog/2`): one statement instead of
  every waiting job being fetched and snoozed one by one.
  """

  use GenServer

  @default_defer_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Take a slot of `channel_id` for the calling process.

    * `{:ok, ref}` - run the delivery, then `release(ref)`
    * `{:full, defer?}` - the channel already has `cap` deliveries running on
      this node; `defer?` is true for the first caller in a `defer_ms` window

  A `nil` cap means no limit.
  """
  def acquire(channel_id, cap, opts \\ [])

  def acquire(_channel_id, nil, _opts), do: {:ok, nil}

  def acquire(channel_id, cap, opts) when is_integer(cap) and cap > 0 do
    server = Keyword.get(opts, :server, __MODULE__)
    defer_ms = Keyword.get(opts, :defer_ms, @default_defer_ms)
    GenServer.call(server, {:acquire, channel_id, cap, defer_ms, self()})
  end

  @doc "Release a slot taken by `acquire/2`."
  def release(ref, opts \\ [])
  def release(nil, _opts), do: :ok

  def release(ref, opts) when is_reference(ref) do
    GenServer.cast(Keyword.get(opts, :server, __MODULE__), {:release, ref})
  end

  @doc "Deliveries of `channel_id` running on this node."
  def count(channel_id, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:count, channel_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{counts: %{}, slots: %{}, deferred_at: %{}}}
  end

  @impl true
  def handle_call({:acquire, channel_id, cap, defer_ms, pid}, _from, state) do
    taken = Map.get(state.counts, channel_id, 0)

    if taken < cap do
      ref = Process.monitor(pid)

      state = %{
        state
        | counts: Map.put(state.counts, channel_id, taken + 1),
          slots: Map.put(state.slots, ref, channel_id)
      }

      {:reply, {:ok, ref}, state}
    else
      now = System.monotonic_time(:millisecond)
      last = Map.get(state.deferred_at, channel_id)
      defer? = is_nil(last) or now - last >= defer_ms

      state =
        if defer?,
          do: %{state | deferred_at: Map.put(state.deferred_at, channel_id, now)},
          else: state

      {:reply, {:full, defer?}, state}
    end
  end

  def handle_call({:count, channel_id}, _from, state) do
    {:reply, Map.get(state.counts, channel_id, 0), state}
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, free(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, free(state, ref)}
  end

  defp free(state, ref) do
    case Map.pop(state.slots, ref) do
      {nil, _} ->
        state

      {channel_id, slots} ->
        counts =
          case Map.fetch!(state.counts, channel_id) do
            1 -> Map.delete(state.counts, channel_id)
            n -> Map.put(state.counts, channel_id, n - 1)
          end

        deferred_at =
          if Map.has_key?(counts, channel_id),
            do: state.deferred_at,
            else: Map.delete(state.deferred_at, channel_id)

        %{state | counts: counts, slots: slots, deferred_at: deferred_at}
    end
  end
end
