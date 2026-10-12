defmodule Converger.TestBrokerAdapter do
  @moduledoc """
  A broker channel adapter (`:consumer` capability) that exists only in
  tests. Its consumer is a Broadway pipeline on `Broadway.DummyProducer`,
  fed with `Broadway.test_message/3`, so the consumer lifecycle and the
  inbound handling are tested without a broker.

  Dead-letter writes and deliveries are sent as messages to the process in
  `Application.get_env(:converger, :test_broker_pid)`. A dead-letter write
  fails while `Application.get_env(:converger, :test_broker_dlq_failures)`
  is a positive count (decremented on each failure).
  """

  use Converger.Channels.Adapter, type: "test_broker"

  @behaviour Converger.Channels.Broker

  @impl true
  def capabilities, do: [:inbound, :outbound, :consumer]

  @impl true
  def config_schema do
    [%{name: "topic_in", type: :string, required: :inbound}]
  end

  @impl true
  def deliver_activity(channel, activity) do
    if Converger.Channels.Broker.echo?(channel, activity) do
      {:ok, %{skipped: "consumed from this channel"}}
    else
      notify({:test_broker_delivered, channel.id, activity.id})
      :ok
    end
  end

  @impl true
  def parse_inbound(_channel, _params), do: {:error, "consumer only"}

  @impl Converger.Channels.Broker
  def consumer_options(_channel) do
    {:ok,
     [
       producer: [module: {Broadway.DummyProducer, []}, concurrency: 1],
       processors: [default: [concurrency: 1]]
     ]}
  end

  @impl Converger.Channels.Broker
  def message_info(_channel, %Broadway.Message{data: data, metadata: metadata}) do
    id = Map.get(metadata, :id)
    %{payload: data, message_id: id, source: "test/#{id}", key: nil, headers: []}
  end

  @impl Converger.Channels.Broker
  def dead_letter(channel, info, reason) do
    case Application.get_env(:converger, :test_broker_dlq_failures, 0) do
      failures when is_integer(failures) and failures > 0 ->
        Application.put_env(:converger, :test_broker_dlq_failures, failures - 1)
        {:error, :dlq_unavailable}

      _ ->
        notify({:test_broker_dead_letter, channel.id, info, reason})
        :ok
    end
  end

  defp notify(message) do
    case Application.get_env(:converger, :test_broker_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> send(self(), message)
    end
  end
end
