defmodule Converger.Channels.Templates do
  @moduledoc """
  The provider message templates (WhatsApp HSM) of a channel, as listed by
  its adapter (`c:Converger.Channels.Adapter.list_templates/1`), cached per
  node for `ttl_ms` so the tenant API does not hit the provider's rate
  limits:

      config :converger, Converger.Channels.Templates, ttl_ms: 300_000

  The process only owns the ETS table; reads and writes go to the table
  directly. A failed listing is not cached.
  """

  use GenServer

  alias Converger.Channels.Adapter

  @table __MODULE__
  @default_ttl_ms 300_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Lists the channel's templates. Options: `refresh: true` skips the cache.

  Returns `{:ok, templates, %{cached: boolean, fetched_at: DateTime.t()}}`,
  `{:error, :unsupported}` for a channel type without templates, or
  `{:error, {:invalid_config, message}}` when the channel config lacks what
  the provider needs, or `{:error, message}` for a provider failure.
  """
  def list(channel, opts \\ []) do
    now = System.monotonic_time(:millisecond)
    refresh? = Keyword.get(opts, :refresh, false)

    case lookup(channel.id) do
      {:ok, templates, fetched_at, expires_at} when expires_at > now and not refresh? ->
        {:ok, templates, %{cached: true, fetched_at: fetched_at}}

      _ ->
        fetch(channel, now)
    end
  end

  @doc "Drops a channel's cached templates (e.g. after its config changed)."
  def invalidate(channel_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, channel_id)
    :ok
  end

  defp fetch(channel, now) do
    case Adapter.list_templates(channel) do
      {:ok, templates} when is_list(templates) ->
        fetched_at = DateTime.utc_now()

        if :ets.whereis(@table) != :undefined,
          do: :ets.insert(@table, {channel.id, templates, fetched_at, now + ttl_ms()})

        {:ok, templates, %{cached: false, fetched_at: fetched_at}}

      :unsupported ->
        {:error, :unsupported}

      {:error, {:invalid_config, message}} ->
        {:error, {:invalid_config, message}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp lookup(channel_id) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, channel_id) do
      [{^channel_id, templates, fetched_at, expires_at}] ->
        {:ok, templates, fetched_at, expires_at}

      _ ->
        :miss
    end
  end

  defp ttl_ms do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, {:read_concurrency, true}])
    {:ok, %{}}
  end
end
