defmodule Converger.Pipeline.Broadway.MemoryProducer do
  @moduledoc """
  In-memory GenStage producer for Broadway pipeline.

  Used when no external message broker (Kafka/RabbitMQ) is configured.
  Messages are pushed directly from the application process.

      config :converger, :pipeline,
        backend: Converger.Pipeline.Broadway,
        broadway: [producer: :memory]
  """

  use GenStage

  @doc "Push a message to the producer for processing."
  def push(message) do
    GenStage.cast(__MODULE__, {:push, message})
  end

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:producer, %{queue: :queue.new(), demand: 0}}
  end

  @impl true
  def handle_cast({:push, message}, state) do
    queue = :queue.in(message, state.queue)
    dispatch(%{state | queue: queue})
  end

  @impl true
  def handle_demand(incoming_demand, state) do
    dispatch(%{state | demand: state.demand + incoming_demand})
  end

  defp dispatch(%{queue: queue, demand: demand} = state) do
    {messages, queue, demand} = take_messages(queue, demand, [])

    events =
      Enum.map(messages, fn msg ->
        %Broadway.Message{
          data: msg,
          acknowledger: {__MODULE__, :ack_id, :ack_data}
        }
      end)

    {:noreply, events, %{state | queue: queue, demand: demand}}
  end

  defp take_messages(queue, 0, acc), do: {Enum.reverse(acc), queue, 0}

  defp take_messages(queue, demand, acc) do
    case :queue.out(queue) do
      {{:value, msg}, queue} -> take_messages(queue, demand - 1, [msg | acc])
      {:empty, queue} -> {Enum.reverse(acc), queue, demand}
    end
  end

  @doc false
  def ack(_ack_ref, _successful, _failed), do: :ok
end
