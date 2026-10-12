defmodule Converger.Channels.Broker.Publishers do
  @moduledoc """
  Per-channel broker connections used to produce: one process per broker
  channel and node (`Converger.Channels.Broker.KafkaPublisher` owns a `:brod`
  client, `Converger.Channels.Broker.AmqpPublisher` an AMQP connection with
  publisher confirms), started on first use under this `DynamicSupervisor`.

  A publisher is registered in `Converger.Channels.Broker.Registry` under
  `{:publisher, channel_id}` with the fingerprint of the channel's config:
  when the config changes, the next delivery replaces it. It stops by itself
  after `:publisher_idle_ms` (default 15 minutes) without use, so deleted or
  disabled channels do not keep connections open.
  """

  use DynamicSupervisor

  alias Converger.Channels.Broker.Registry, as: BrokerRegistry

  def start_link(arg), do: DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "The fingerprint of the connection-relevant parts of a channel."
  @spec fingerprint(map()) :: integer()
  def fingerprint(channel), do: :erlang.phash2({channel.type, channel.config})

  @doc "The registered name of the publisher of `channel`, carrying its fingerprint."
  def via(channel),
    do: {:via, Registry, {BrokerRegistry, {:publisher, channel.id}, fingerprint(channel)}}

  @doc """
  The running publisher (a `module` process) of `channel`, started or
  replaced when its config changed. Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec ensure(module(), map()) :: {:ok, pid()} | {:error, term()}
  def ensure(module, channel) do
    fingerprint = fingerprint(channel)

    case Registry.lookup(BrokerRegistry, {:publisher, channel.id}) do
      [{pid, ^fingerprint}] ->
        {:ok, pid}

      [{pid, _stale}] ->
        _ = DynamicSupervisor.terminate_child(__MODULE__, pid)
        start(module, channel)

      [] ->
        start(module, channel)
    end
  end

  defp start(module, channel) do
    case DynamicSupervisor.start_child(__MODULE__, {module, channel}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stop the publisher of `channel_id` on this node, if any."
  @spec stop(String.t()) :: :ok
  def stop(channel_id) do
    for {pid, _} <- Registry.lookup(BrokerRegistry, {:publisher, channel_id}) do
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end

    :ok
  end

  @doc "Idle time after which a publisher stops."
  def idle_ms do
    Keyword.get(
      Application.get_env(:converger, :broker_channels, []),
      :publisher_idle_ms,
      900_000
    )
  end
end
