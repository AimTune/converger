defmodule Converger.RateLimit.Overrides do
  @moduledoc """
  Per-tenant rate-limit overrides (`tenants.limits`), cached in ETS.

  Rate limits are checked before the request touches the database, so the
  tenant overrides are cached for `:override_cache_ttl_ms` (default 30s).
  `invalidate_tenant/1` clears the entry on every node (locally right away,
  remotely over PubSub) when a tenant's limits change.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  alias Converger.Repo
  alias Converger.Channels.Channel
  alias Converger.Tenants.Tenant

  @table __MODULE__
  @topic "converger:rate_limit_overrides"
  @default_ttl_ms 30_000

  @type tenant_ref :: %Tenant{} | Ecto.UUID.t() | {:channel, String.t()} | nil

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the overrides map (`%{"bucket" => %{"limit" => n, "scale_ms" => ms}}`)
  for a tenant struct, a tenant id or `{:channel, channel_id}`.
  """
  @spec limits_for(tenant_ref()) :: map()
  def limits_for(%Tenant{limits: limits}) when is_map(limits), do: limits
  def limits_for(%Tenant{}), do: %{}
  def limits_for(nil), do: %{}

  def limits_for({:channel, channel_id}) do
    case cached({:channel, channel_id}, fn -> channel_tenant_id(channel_id) end) do
      nil -> %{}
      tenant_id -> limits_for(tenant_id)
    end
  end

  def limits_for(tenant_id) when is_binary(tenant_id) do
    cached({:tenant, tenant_id}, fn -> tenant_limits(tenant_id) end) || %{}
  end

  def limits_for(_other), do: %{}

  @doc "Drops the cached overrides of a tenant on all nodes."
  @spec invalidate_tenant(Ecto.UUID.t()) :: :ok
  def invalidate_tenant(tenant_id) do
    delete_local(tenant_id)
    Phoenix.PubSub.broadcast_from(Converger.PubSub, self(), @topic, {:invalidate, tenant_id})
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, {:read_concurrency, true}])
    :ok = Phoenix.PubSub.subscribe(Converger.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:invalidate, tenant_id}, state) do
    delete_local(tenant_id)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp delete_local(tenant_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, {:tenant, tenant_id})
  end

  defp cached(key, fun) do
    now = System.monotonic_time(:millisecond)

    case lookup(key) do
      {:ok, value, expires_at} when expires_at > now ->
        value

      _ ->
        value = fun.()
        if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {key, value, now + ttl()})
        value
    end
  end

  defp lookup(key) do
    case :ets.whereis(@table) != :undefined && :ets.lookup(@table, key) do
      [{^key, value, expires_at}] -> {:ok, value, expires_at}
      _ -> :miss
    end
  end

  defp ttl do
    Application.get_env(:converger, Converger.RateLimit, [])
    |> Keyword.get(:override_cache_ttl_ms, @default_ttl_ms)
  end

  defp tenant_limits(tenant_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(tenant_id) do
      Repo.one(from t in Tenant, where: t.id == ^uuid, select: t.limits)
    else
      _ -> nil
    end
  end

  defp channel_tenant_id(channel_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(channel_id) do
      Repo.one(from c in Channel, where: c.id == ^uuid, select: c.tenant_id)
    else
      _ -> nil
    end
  end
end
