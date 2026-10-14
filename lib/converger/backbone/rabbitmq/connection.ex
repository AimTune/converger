defmodule Converger.Backbone.RabbitMQ.Connection do
  @moduledoc """
  Owns the AMQP connection and the confirm-mode channel the RabbitMQ
  backbone publishes with, and declares the backbone exchange. Publishes are
  serialised through this process and wait for the broker's confirm. A
  broker that is unreachable (at boot or later) does not stop the node: the
  connection is retried every 5 s, and publishes fail meanwhile, which parks
  the events in Postgres (`Converger.Workers.BackbonePublishWorker`).
  """

  use GenServer

  require Logger

  alias Converger.Backbone.RabbitMQ

  @retry_ms 5_000

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @doc "Publish and wait for the broker's confirm."
  @spec publish(String.t(), String.t(), binary(), keyword(), pos_integer()) ::
          :ok | {:error, term()}
  def publish(exchange, routing_key, payload, opts, timeout) do
    GenServer.call(
      __MODULE__,
      {:publish, exchange, routing_key, payload, opts, timeout},
      timeout + 5_000
    )
  catch
    :exit, reason -> {:error, {:connection_down, reason}}
  end

  @impl true
  def init(config) do
    {:ok, %{config: config, conn: nil, chan: nil}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    with {:ok, options} <- RabbitMQ.connection_options(),
         {:ok, conn} <- AMQP.Connection.open(options),
         {:ok, chan} <- open_channel(conn) do
      Process.monitor(conn.pid)
      declare_subscriptions(chan)
      {:noreply, %{state | conn: conn, chan: chan}}
    else
      {:error, reason} ->
        Logger.warning("RabbitMQ backbone not connected; retrying", error: inspect(reason))
        Process.send_after(self(), :connect, @retry_ms)
        {:noreply, %{state | conn: nil, chan: nil}}
    end
  end

  defp open_channel(conn) do
    with {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Confirm.select(chan),
         :ok <- RabbitMQ.declare_exchange(chan, RabbitMQ.exchange()) do
      {:ok, chan}
    else
      error ->
        AMQP.Connection.close(conn)
        error
    end
  end

  # The queues of the shared subscriptions declared on this node, so events
  # published from now on reach them even before their consumers run.
  defp declare_subscriptions(chan) do
    for %{mode: :shared} = subscription <- Converger.Backbone.Registry.all() do
      case RabbitMQ.declare_queue(chan, subscription) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("RabbitMQ backbone queue not declared",
            subscription: subscription.name,
            error: inspect(reason)
          )
      end
    end
  end

  @doc """
  Declare the queue of `subscription` and bind it to its topics. Returns
  `{:error, :not_connected}` while the broker is unreachable (the queue is
  declared on connect).
  """
  @spec declare(Converger.Backbone.Subscription.t()) :: :ok | {:error, term()}
  def declare(subscription) do
    GenServer.call(__MODULE__, {:declare, subscription}, 15_000)
  catch
    :exit, reason -> {:error, {:connection_down, reason}}
  end

  @impl true
  def handle_call({:declare, _subscription}, _from, %{chan: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:declare, subscription}, _from, state) do
    {:reply, RabbitMQ.declare_queue(state.chan, subscription), state}
  catch
    :exit, reason ->
      Process.send_after(self(), :connect, @retry_ms)
      {:reply, {:error, {:channel_closed, reason}}, %{state | conn: nil, chan: nil}}
  end

  def handle_call(
        {:publish, _exchange, _key, _payload, _opts, _timeout},
        _from,
        %{chan: nil} = state
      ),
      do: {:reply, {:error, :not_connected}, state}

  def handle_call({:publish, exchange, routing_key, payload, opts, timeout}, _from, state) do
    result =
      with :ok <- AMQP.Basic.publish(state.chan, exchange, routing_key, payload, opts) do
        case AMQP.Confirm.wait_for_confirms(state.chan, {timeout, :millisecond}) do
          true -> :ok
          false -> {:error, :nacked}
          :timeout -> {:error, :confirm_timeout}
        end
      end

    {:reply, result, state}
  catch
    :exit, reason ->
      Process.send_after(self(), :connect, @retry_ms)
      {:reply, {:error, {:channel_closed, reason}}, %{state | conn: nil, chan: nil}}
  end

  @impl true
  def handle_info(:connect, %{conn: nil} = state), do: {:noreply, state, {:continue, :connect}}
  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{conn: %{pid: pid}} = state) do
    Logger.warning("RabbitMQ backbone connection closed; reconnecting", reason: inspect(reason))
    Process.send_after(self(), :connect, @retry_ms)
    {:noreply, %{state | conn: nil, chan: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    if Process.alive?(conn.pid), do: AMQP.Connection.close(conn)
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
