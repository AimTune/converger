defmodule Converger.Channels.Consumers.Manager do
  @moduledoc """
  Keeps the broker consumers of the cluster in line with the channels. One
  manager runs on every node with consumers enabled.

  A reconciliation, for every broker channel that should consume (active,
  mode `inbound` or `duplex`, see `Converger.Channels.Broker.consumes?/1`):

    * a consumer running **on this node** with an outdated fingerprint
      (config, mode, status changed) is restarted;
    * a channel without a consumer **anywhere** in the cluster gets one, from
      the node that owns the channel: the highest
      `:erlang.phash2({node, channel_id})` among the connected nodes
      (rendezvous hashing, which spreads consumers over the nodes). Another
      node starts it when it is still missing on the next reconciliation, in
      case the owner cannot;

  and consumers on this node whose channel no longer consumes (disabled,
  switched to `outbound`, deleted) are stopped. Whatever happens, the
  `:global` registration of `Converger.Channels.Broker.Consumer` keeps it to
  one consumer per channel.

  It reconciles one channel when `Converger.Channels` reports a change
  (`Converger.Channels.Consumers.notify_changed/1`), everything on a node
  joining or leaving, and everything every `reconcile_interval_ms` (default
  30 s), which also restarts consumers that gave up.
  """

  use GenServer

  require Logger

  alias Converger.Channels
  alias Converger.Channels.Broker
  alias Converger.Channels.Broker.Consumer
  alias Converger.Channels.Consumers

  @initial_delay_ms 1_000
  @node_change_delay_ms 2_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Reconcile now and wait for it (tests, operations)."
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile, 60_000)

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Converger.PubSub, Consumers.topic())
    :ok = :net_kernel.monitor_nodes(true)

    interval =
      Keyword.get_lazy(opts, :interval_ms, fn ->
        Keyword.get(
          Application.get_env(:converger, :broker_channels, []),
          :reconcile_interval_ms,
          30_000
        )
      end)

    Process.send_after(
      self(),
      :reconcile,
      Keyword.get(opts, :initial_delay_ms, @initial_delay_ms)
    )

    {:ok, %{interval: interval, missing: %{}, timer: nil}}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    {:reply, :ok, reconcile_all(state)}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state = reconcile_all(state)
    {:noreply, %{state | timer: Process.send_after(self(), :reconcile, state.interval)}}
  end

  def handle_info({:channel_changed, channel_id}, state) do
    {:noreply, reconcile_one(channel_id, state)}
  end

  def handle_info({event, _node}, state) when event in [:nodeup, :nodedown] do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :reconcile, @node_change_delay_ms)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Reconciliation

  defp reconcile_all(state) do
    channels = Channels.list_consumer_channels()
    wanted = MapSet.new(channels, & &1.id)

    for id <- Consumers.local_channel_ids(), not MapSet.member?(wanted, id) do
      stop(id, "channel no longer consumes")
    end

    missing = Enum.reduce(channels, %{}, &ensure(&1, &2, state.missing))
    %{state | missing: missing}
  rescue
    exception ->
      Logger.error("Broker consumer reconciliation failed", error: Exception.message(exception))
      state
  end

  defp reconcile_one(channel_id, state) do
    case Channels.get_channel(channel_id) do
      nil ->
        stop(channel_id, "channel deleted")
        state

      channel ->
        if Broker.consumes?(channel) do
          missing = ensure(channel, Map.delete(state.missing, channel_id), state.missing)
          %{state | missing: missing}
        else
          stop(channel_id, "channel no longer consumes")
          %{state | missing: Map.delete(state.missing, channel_id)}
        end
    end
  rescue
    exception ->
      Logger.error("Broker consumer reconciliation failed",
        channel_id: channel_id,
        error: Exception.message(exception)
      )

      state
  end

  # Returns the "missing" map for the next round: channel id => rounds in
  # which no node ran a consumer.
  defp ensure(channel, acc, previous) do
    fingerprint = Consumer.fingerprint(channel)

    case Consumers.local(channel.id) do
      {_pid, ^fingerprint} ->
        acc

      {_pid, _stale} ->
        stop(channel.id, "channel changed")
        start(channel)
        acc

      nil ->
        cond do
          Consumer.whereis(channel.id) ->
            acc

          owner?(channel.id) or Map.get(previous, channel.id, 0) >= 1 ->
            start(channel)
            acc

          true ->
            Map.put(acc, channel.id, Map.get(previous, channel.id, 0) + 1)
        end
    end
  end

  defp start(channel, retried? \\ false) do
    case Consumers.start_consumer(channel) do
      # The consumer was just stopped here and :global has not dropped its
      # name yet.
      {:error, {:already_started, pid}}
      when not retried? and node(pid) == node() ->
        if Process.alive?(pid) do
          :ok
        else
          Process.sleep(50)
          start(channel, true)
        end

      {:ok, _pid} ->
        Logger.info("Broker consumer started", channel_id: channel.id, channel_type: channel.type)

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Broker consumer could not start",
          channel_id: channel.id,
          channel_type: channel.type,
          reason: inspect(reason)
        )
    end
  end

  defp stop(channel_id, why) do
    if Consumers.local(channel_id) do
      Consumers.stop_consumer(channel_id)
      Logger.info("Broker consumer stopped: #{why}", channel_id: channel_id)
    end
  end

  @doc false
  def owner?(channel_id, nodes \\ [node() | Node.list()]) do
    Enum.max_by(nodes, &:erlang.phash2({&1, channel_id})) == node()
  end
end
