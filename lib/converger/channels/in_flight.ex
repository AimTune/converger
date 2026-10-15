defmodule Converger.Channels.InFlight do
  @moduledoc """
  Per-node cap on the deliveries of one channel that run at the same time
  (ADR-0076).

  Before its breaker opens, a dead channel's backlog would take every worker of
  its tier queue, each waiting one adapter timeout, and the queue would run
  nothing else (#191). `acquire/2` gives a delivery job a slot of its channel
  while the channel is under its cap on this node; a job over the cap is
  snoozed by the worker and does not touch the database.

  Slots are held by the job process and released by `release/1`, or when the
  process exits (the server monitors it), so a killed job cannot leak a slot.

  For a channel at its cap, `acquire/2` also tells the caller, at most once per
  `demote_ms`, to demote the channel's waiting backlog
  (`Converger.Channels.Circuit.demote_backlog/1`): one statement that puts it
  behind other channels' fresh deliveries, instead of every waiting job being
  fetched and snoozed ahead of them.
  """

  use GenServer

  @default_demote_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Take a slot of `channel_id` for the calling process; `cap` is a positive
  integer, or `nil` for no cap.

    * `{:ok, ref}` - run the delivery, then `release(ref)`
    * `{:full, demote?}` - the channel already runs `cap` deliveries on this
      node; `demote?` is true for the first caller in a `demote_ms` window
  """
  def acquire(channel_id, cap, opts \\ [])

  def acquire(_channel_id, nil, _opts), do: {:ok, nil}

  def acquire(channel_id, cap, opts) when is_integer(cap) and cap > 0 do
    server = Keyword.get(opts, :server, __MODULE__)
    demote_ms = Keyword.get(opts, :demote_ms, @default_demote_ms)
    GenServer.call(server, {:acquire, channel_id, cap, demote_ms, self()})
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
    {:ok, %{counts: %{}, slots: %{}, demoted_at: %{}}}
  end

  @impl true
  def handle_call({:acquire, channel_id, cap, demote_ms, pid}, _from, state) do
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
      last = Map.get(state.demoted_at, channel_id)
      demote? = is_nil(last) or now - last >= demote_ms

      state =
        if demote?,
          do: %{state | demoted_at: Map.put(state.demoted_at, channel_id, now)},
          else: state

      {:reply, {:full, demote?}, state}
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

        demoted_at =
          if Map.has_key?(counts, channel_id),
            do: state.demoted_at,
            else: Map.delete(state.demoted_at, channel_id)

        %{state | counts: counts, slots: slots, demoted_at: demoted_at}
    end
  end
end
