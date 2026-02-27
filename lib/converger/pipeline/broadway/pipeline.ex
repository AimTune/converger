defmodule Converger.Pipeline.Broadway.Pipeline do
  @moduledoc """
  Broadway pipeline that processes activity delivery messages.

  Messages flow through:
  1. Producer (memory/Kafka/RabbitMQ)
  2. Processor (resolve activity + channel, decide batcher)
  3. Delivery batcher (batch deliver to external channels)
  """

  use Broadway

  require Logger

  alias Converger.{Activities, Channels}
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

        {:error, reason} ->
          Logger.warning("Broadway delivery failed",
            activity_id: activity.id,
            channel_id: channel.id,
            error: inspect(reason)
          )

          Broadway.Message.failed(message, inspect(reason))
      end
    end)
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
