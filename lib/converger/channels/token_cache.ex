defmodule Converger.Channels.TokenCache do
  @moduledoc """
  Per-node cache of short-lived provider credentials and keys: the Bot
  Framework OAuth access tokens and signing keys of the `teams` adapter.
  Entries expire after their own TTL; nothing is persisted, so a restart
  only costs one fetch per entry.

  The process only owns the ETS table; reads and writes go to the table
  directly. Without the table (a process that is not running) every lookup
  is a miss and writes are dropped, so callers always work, uncached.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The value stored under `key`, unless expired: `{:ok, value}` or `:miss`."
  def get(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  end

  @doc "Stores `value` under `key` for `ttl_ms` milliseconds."
  def put(key, value, ttl_ms) when is_integer(ttl_ms) do
    if :ets.whereis(@table) != :undefined,
      do: :ets.insert(@table, {key, value, System.monotonic_time(:millisecond) + ttl_ms})

    :ok
  end

  @doc "Drops `key` (e.g. a token the provider rejected)."
  def delete(key) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key)
    :ok
  end

  @doc """
  The cached value of `key`, or the result of `fun.()` cached for its TTL.
  `fun` returns `{:ok, value, ttl_ms}` or an error, which is returned as is
  and not cached.
  """
  def fetch(key, fun) do
    case get(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        case fun.() do
          {:ok, value, ttl_ms} ->
            put(key, value, ttl_ms)
            {:ok, value}

          error ->
            error
        end
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, {:read_concurrency, true}])
    {:ok, %{}}
  end
end
