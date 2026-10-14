defmodule Converger.Backbone.Kafka.Client do
  @moduledoc """
  Owns the `:brod` client the Kafka backbone publishes with, and creates the
  backbone topics when they are missing (`create_topics: true`).

  A broker that is unreachable at boot does not stop the node: topic
  creation is retried every 5 s, and publishes fail meanwhile, which parks
  the events in Postgres (`Converger.Workers.BackbonePublishWorker`) until
  the broker is back. When the client exits it is started again.
  """

  use GenServer

  require Logger

  alias Converger.Backbone
  alias Converger.Backbone.Kafka
  alias Converger.Channels.Adapters.Kafka, as: KafkaAdapter

  @retry_ms 2_000

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    state = %{
      config: config,
      client: Keyword.get(config, :client, Kafka.client()),
      pid: nil,
      topics_ready: false
    }

    case Kafka.channel_config(config) |> KafkaAdapter.hosts() do
      {:ok, hosts} ->
        state = Map.put(state, :hosts, hosts)
        {:ok, start_client(state), {:continue, :create_topics}}

      {:error, message} ->
        {:stop, {:invalid_config, message}}
    end
  end

  defp start_client(state) do
    client_config =
      state.config
      |> Kafka.channel_config()
      |> KafkaAdapter.client_config()
      |> Keyword.merge(
        auto_start_producers: true,
        # A topic created after the client first asked for it must not stay
        # "unknown" for brod's default two minutes.
        unknown_topic_cache_ttl: 1_000,
        default_producer_config: [required_acks: -1, max_retries: 3, retry_backoff_ms: 200]
      )

    case :brod_client.start_link(state.hosts, state.client, client_config) do
      {:ok, pid} ->
        %{state | pid: pid}

      {:error, reason} ->
        Logger.warning("Kafka backbone client did not start; retrying", error: inspect(reason))
        Process.send_after(self(), :start_client, @retry_ms)
        state
    end
  end

  @doc "Whether the backbone topics exist (or creating them is turned off)."
  @spec ready?() :: boolean()
  def ready? do
    GenServer.call(__MODULE__, :ready?)
  catch
    :exit, _ -> false
  end

  @impl true
  def handle_continue(:create_topics, state) do
    if (not Keyword.get(state.config, :create_topics, true) or create_topics(state)) and
         topics_visible?(state) do
      {:noreply, %{state | topics_ready: true}}
    else
      Process.send_after(self(), :create_topics, @retry_ms)
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state),
    do: {:reply, state.topics_ready and is_pid(state.pid), state}

  @impl true
  def handle_info(:create_topics, state), do: {:noreply, state, {:continue, :create_topics}}
  def handle_info(:start_client, %{pid: nil} = state), do: {:noreply, start_client(state)}
  def handle_info(:start_client, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    Logger.warning("Kafka backbone client stopped; restarting", reason: inspect(reason))
    Process.send_after(self(), :start_client, 1_000)
    {:noreply, %{state | pid: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{pid: pid}) do
    if is_pid(pid) and Process.alive?(pid), do: :brod_client.stop(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  # true when every topic exists (created now or before).
  defp create_topics(state) do
    configs =
      for topic <- Backbone.topics() do
        %{
          name: Backbone.topic_name(topic),
          num_partitions: Keyword.get(state.config, :partitions, 12),
          replication_factor: Keyword.get(state.config, :replication_factor, 1),
          assignments: [],
          configs: []
        }
      end

    conn_config =
      state.config
      |> Kafka.channel_config()
      |> KafkaAdapter.client_config()
      |> Keyword.take([:ssl, :sasl, :connect_timeout])

    Enum.all?(configs, fn config ->
      case :brod.create_topics(state.hosts, [config], %{timeout: 15_000}, conn_config) do
        :ok ->
          true

        {:error, reason} ->
          if exists?(reason) do
            true
          else
            Logger.warning(
              "Kafka backbone topic #{config.name} not created (#{inspect(reason)}); retrying"
            )

            false
          end
      end
    end)
  catch
    :exit, reason ->
      Logger.warning("Kafka backbone topics not created; retrying", error: inspect(reason))
      false
  end

  # The client sees partitions for every topic (metadata propagated).
  defp topics_visible?(%{pid: nil}), do: false

  defp topics_visible?(state) do
    Enum.all?(Backbone.topics(), fn topic ->
      match?(
        {:ok, count} when count > 0,
        :brod_client.get_partitions_count_safe(state.client, Backbone.topic_name(topic))
      )
    end)
  catch
    :exit, _ -> false
  end

  defp exists?(reason), do: inspect(reason) =~ ~r/topic_already_exists|already exists/i
end
