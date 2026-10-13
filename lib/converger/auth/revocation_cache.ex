defmodule Converger.Auth.RevocationCache do
  @moduledoc """
  Per-node ETS copy of `revoked_tokens` (`Converger.Auth.Revocations`), so
  checking a token costs one ETS lookup per key, never a query.

  Kept current three ways:

    * the node that revokes writes its own table before answering;
    * every revocation is broadcast on `Converger.PubSub`, and every node's
      cache inserts it on arrival (milliseconds across the cluster, which is
      what bounds "a revoked token is rejected everywhere within 1 s");
    * every `:sync_interval_ms` (default 60 s) the cache reads the rows
      revoked since its last read, with an overlap, which repairs anything a
      broadcast missed (a node that was partitioned or restarting).

  On start the whole table is loaded. If the database is unavailable then,
  the cache starts empty and the next sync loads it.

      config :converger, Converger.Auth.RevocationCache, sync_interval_ms: 60_000
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Converger.Auth.RevokedToken
  alias Converger.Repo

  @table __MODULE__
  @topic "auth:token_revocations"
  # Rows revoked this long before the last sync are read again: covers clock
  # differences between the nodes that write `revoked_at`.
  @overlap_ms 120_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The PubSub topic revocations are broadcast on."
  def topic, do: @topic

  @doc "The cached entry of `key`: `{kind, revoked_at_ms}`, or nil."
  def lookup(key) do
    now = System.system_time(:millisecond)

    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, key) do
      [{^key, kind, revoked_at, expires_at}] when expires_at > now -> {kind, revoked_at}
      _ -> nil
    end
  end

  @doc "Inserts revoked token rows into this node's table."
  def insert(rows) do
    if :ets.whereis(@table) != :undefined,
      do: :ets.insert(@table, Enum.map(rows, &entry/1))

    :ok
  end

  @doc "Inserts `rows` locally and broadcasts them to every node's cache."
  def publish(rows) do
    insert(rows)
    Phoenix.PubSub.broadcast(Converger.PubSub, @topic, {:token_revocations, rows})
    :ok
  end

  @doc "Reads the rows changed since the last sync now (tests, operations)."
  def sync, do: GenServer.call(__MODULE__, :sync)

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Converger.PubSub, @topic)

    interval =
      Keyword.get_lazy(opts, :sync_interval_ms, fn ->
        :converger
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:sync_interval_ms, 60_000)
      end)

    state = %{interval: interval, synced_at: nil}
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    state = do_sync(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, do_sync(state)}

  @impl true
  def handle_info({:token_revocations, rows}, state) do
    insert(rows)
    {:noreply, state}
  end

  def handle_info(:sync, state) do
    state = do_sync(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(%{interval: interval}) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :sync, interval)

  defp schedule(_state), do: :ok

  defp do_sync(state) do
    now = DateTime.utc_now()
    started = System.system_time(:millisecond)

    query =
      case state.synced_at do
        nil -> from(r in RevokedToken, where: r.expires_at > ^now)
        since -> from(r in RevokedToken, where: r.expires_at > ^now and r.revoked_at > ^since)
      end

    query |> Repo.all() |> insert()

    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", started}], [true]}])
    %{state | synced_at: DateTime.add(now, -@overlap_ms, :millisecond)}
  rescue
    error ->
      Logger.warning("Token revocation sync failed: #{Exception.message(error)}")
      state
  end

  defp entry(%RevokedToken{} = row) do
    {row.key, row.kind, DateTime.to_unix(row.revoked_at, :millisecond),
     DateTime.to_unix(row.expires_at, :millisecond)}
  end
end
