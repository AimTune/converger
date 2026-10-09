defmodule ConvergerWeb.DeliveryJSON do
  alias Converger.Deliveries
  alias Converger.Deliveries.Delivery

  @doc """
  Renders a page of deliveries.
  """
  def index(%{deliveries: deliveries} = assigns) do
    body = %{data: for(delivery <- deliveries, do: data(delivery))}

    case assigns do
      %{meta: %{} = meta} -> Map.put(body, :meta, meta)
      _ -> body
    end
  end

  @doc """
  Renders a single delivery.
  """
  def show(%{delivery: delivery}) do
    %{data: data(delivery)}
  end

  # `payload` is the canonical activity with sensitive keys redacted
  # (`Deliveries.payload_preview/1`); `:activity` must be preloaded.
  defp data(%Delivery{} = delivery) do
    %{
      id: delivery.id,
      activity_id: delivery.activity_id,
      channel_id: delivery.channel_id,
      status: delivery.status,
      attempts: delivery.attempts,
      last_error: delivery.last_error,
      provider_message_id: delivery.provider_message_id,
      sent_at: delivery.sent_at,
      delivered_at: delivery.delivered_at,
      read_at: delivery.read_at,
      retry_count: delivery.retry_count,
      retried_by: delivery.retried_by,
      retried_at: delivery.retried_at,
      payload: Deliveries.payload_preview(delivery),
      inserted_at: delivery.inserted_at,
      updated_at: delivery.updated_at
    }
  end
end
