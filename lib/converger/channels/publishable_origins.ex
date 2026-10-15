defmodule Converger.Channels.PublishableOrigins do
  @moduledoc """
  The allowed origins of every active channel with a publishable key
  (ADR-0074), cached per node for `ttl_ms` because CORS consults them on
  client API requests:

      config :converger, Converger.Channels.PublishableOrigins, ttl_ms: 30_000

  `ConvergerWeb.Endpoint.cors_origins/1` allows these origins on
  `/api/v1/converger/*` in addition to `CORS_ORIGINS`, so a widget on a
  customer's site can refresh its token, page history and upload files
  without an operator change. A change through `Converger.Channels`
  invalidates this node's cache; other nodes pick it up within the TTL.

  The process only owns the ETS table; reads and writes go to the table
  directly. When the database is unreachable the last list (or none) is
  used, so CORS never fails a request.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  alias Converger.Channels.{Channel, Origins}

  require Logger

  @table __MODULE__
  @key :origins
  @default_ttl_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "The normalized allowed origins of all active publishable keys."
  def all do
    now = System.monotonic_time(:millisecond)

    case lookup() do
      {:ok, origins, expires_at} when expires_at > now -> origins
      stale -> refresh(now, stale)
    end
  end

  @doc "Whether `origin` is allowed by some active publishable key."
  def allowed?(origin), do: Origins.allowed?(origin, all())

  @doc "Drops this node's cached list."
  def invalidate do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, @key)
    :ok
  end

  defp lookup do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, @key) do
        [{@key, origins, expires_at}] -> {:ok, origins, expires_at}
        [] -> :miss
      end
    else
      :miss
    end
  end

  defp refresh(now, stale) do
    origins =
      from(c in Channel,
        where: not is_nil(c.publishable_key) and c.status == "active",
        select: c.allowed_origins
      )
      |> Converger.Repo.all()
      |> List.flatten()
      |> Enum.uniq()

    if :ets.whereis(@table) != :undefined,
      do: :ets.insert(@table, {@key, origins, now + ttl_ms()})

    origins
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Publishable origins unavailable: #{Exception.message(error)}")

      case stale do
        {:ok, origins, _expired_at} -> origins
        :miss -> []
      end
  end

  defp ttl_ms do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end
end
