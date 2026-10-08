defmodule Converger.Pipeline.Broadway.Pipeline do
  @moduledoc """
  Broadway pipeline that processes activity delivery messages.

  Messages flow through:
  1. Producer (memory/Kafka/RabbitMQ)
  2. Processor (resolve activity + channel, decide batcher)
  3. Delivery batcher (batch deliver to external channels)

  Transient delivery failures are handed off to `Converger.Workers.ActivityDeliveryWorker`
  (Oban) for durable retries with `Converger.Pipeline.RetryPolicy` backoff.
  Deliveries that are out of retries or halted by middleware are dead-lettered
  (`status: "failed"`, see `Converger.Deliveries.list_dead_letters/1`).
  """

  use Broadway

  require Logger

  alias Converger.{Activities, Channels, Deliveries}
  alias Converger.Pipeline

  @impl true
  def handle_message(_processor, message, _context) do
    data = decode_message(message)

    case data do
      %{activity_id: activity_id, channel_id: channel_id} ->
        message
        |> Broadway.Message.update_data(fn _ ->
          %{
            activity: Activities.get_activity!(activity_id),
            channel: Channels.get_channel!(channel_id)
          }
        end)
        |> Broadway.Message.put_batcher(:delivery)

      _ ->
        Broadway.Message.failed(message, "invalid message format")
    end
  rescue
    e ->
      Logger.error("Broadway processor error: #{inspect(e)}")
      Broadway.Message.failed(message, inspect(e))
  end

  @impl true
  def handle_batch(:delivery, messages, _batch_info, _context) do
    Enum.map(messages, fn message ->
      %{activity: activity, channel: channel} = message.data

      case Pipeline.deliver(activity, channel) do
        :ok ->
          Logger.info("Broadway delivery success",
            activity_id: activity.id,
            channel_id: channel.id
          )

          message

        {:error, reason} = result ->
          Logger.warning("Broadway delivery failed",
            activity_id: activity.id,
            channel_id: channel.id,
            error: inspect(reason)
          )

          if Pipeline.retryable?(result),
            do: hand_off_retry(message, activity, channel, reason),
            else: Broadway.Message.failed(message, inspect(reason))
      end
    end)
  end

  # Broadway for throughput, Oban for retries: a transient failure becomes a
  # durable, backed-off Oban job and the message is acked, since Oban now owns
  # the delivery. Only if the hand-off itself fails is the message failed.
  defp hand_off_retry(message, activity, channel, error) do
    delivery = Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)

    case Pipeline.schedule_retry(delivery, delivery.attempts, channel: channel, error: error) do
      {:ok, _job} ->
        message

      {:error, reason} ->
        Logger.error("Broadway retry hand-off failed",
          activity_id: activity.id,
          channel_id: channel.id,
          error: inspect(reason)
        )

        Broadway.Message.failed(message, "retry hand-off failed: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_failed(messages, _context) do
    Enum.each(messages, fn message ->
      Logger.warning("Broadway message failed",
        data: inspect(message.data),
        status: inspect(message.status)
      )
    end)

    messages
  end

  defp decode_message(message) do
    case message.data do
      %{activity_id: _, channel_id: _} = data ->
        data

      data when is_binary(data) ->
        case Jason.decode(data) do
          {:ok, %{"activity_id" => aid, "channel_id" => cid}} ->
            %{activity_id: aid, channel_id: cid}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end
end
