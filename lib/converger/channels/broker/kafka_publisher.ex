defmodule Converger.Channels.Broker.KafkaPublisher do
  @moduledoc """
  Owns the `:brod` client a `kafka` channel produces with on this node (see
  `Converger.Channels.Broker.Publishers`). Producing itself runs in the
  caller (`produce/5`): the process only holds the client, so concurrent
  deliveries do not queue behind each other.

  `:brod` names its clients with atoms; the client of a channel is
  `:"converger_kafka_<channel id>"`, one atom per Kafka channel.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Converger.Channels.Adapters.Kafka
  alias Converger.Channels.Broker.Publishers

  def start_link(channel),
    do: GenServer.start_link(__MODULE__, channel, name: Publishers.via(channel))

  @doc """
  Produce `value` (with `headers`) to `topic` with `key`, on the partition
  `:erlang.phash2(key, partitions)`, and wait up to `timeout` ms for the
  broker's acknowledgement. Returns `{:ok, partition, offset}`.
  """
  @spec produce(map(), String.t(), binary(), binary(), keyword()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, term()}
  def produce(channel, topic, key, value, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    headers = Keyword.get(opts, :headers, [])

    with {:ok, pid} <- Publishers.ensure(__MODULE__, channel),
         {:ok, client} <- client(pid),
         {:ok, count} <- partitions_count(client, topic) do
      partition = :erlang.phash2(key, count)
      message = %{ts: System.system_time(:millisecond), value: value, headers: headers}

      with {:ok, call_ref} <- :brod.produce(client, topic, partition, key, message),
           {:ok, offset} <- :brod.sync_produce_request_offset(call_ref, timeout) do
        {:ok, partition, offset}
      end
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp client(pid) do
    {:ok, GenServer.call(pid, :client)}
  catch
    :exit, reason -> {:error, {:publisher_down, reason}}
  end

  defp partitions_count(client, topic) do
    case :brod.get_partitions_count(client, topic) do
      {:ok, count} when count > 0 -> {:ok, count}
      {:ok, _} -> {:error, :no_partitions}
      {:error, _} = error -> error
    end
  end

  @doc "The `:brod` client name of a channel."
  @spec client_name(String.t()) :: atom()
  # One atom per Kafka channel, from its validated UUID (not from input).
  # sobelow_skip ["DOS.BinToAtom"]
  def client_name(channel_id) do
    {:ok, uuid} = Ecto.UUID.cast(channel_id)
    :"converger_kafka_#{uuid}"
  end

  @impl true
  def init(channel) do
    Process.flag(:trap_exit, true)
    client = client_name(channel.id)

    with {:ok, hosts} <- Kafka.hosts(channel.config || %{}),
         {:guard, :ok} <- {:guard, Kafka.check_hosts(hosts)} do
      config =
        channel.config
        |> Kafka.client_config()
        |> Keyword.merge(
          auto_start_producers: true,
          default_producer_config: [required_acks: -1, max_retries: 0]
        )

      case :brod_client.start_link(hosts, client, config) do
        {:ok, pid} ->
          {:ok, %{client: client, pid: pid, idle_ms: Publishers.idle_ms()}, Publishers.idle_ms()}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      # A host the SSRF guard rejects (its DNS changed since the config was
      # validated): permanent, see Kafka.normalize_error/1.
      {:guard, {:error, message}} -> {:stop, {:target_blocked, message}}
      {:error, reason} -> {:stop, {:invalid_config, reason}}
    end
  end

  @impl true
  def handle_call(:client, _from, state), do: {:reply, state.client, state, state.idle_ms}

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    Logger.warning("Kafka client #{state.client} stopped", reason: inspect(reason))
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state, state.idle_ms}

  @impl true
  def terminate(_reason, %{pid: pid}) do
    if Process.alive?(pid), do: :brod_client.stop(pid)
    :ok
  end
end
