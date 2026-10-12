defmodule ConvergerWeb.WebhookEventJSON do
  alias Converger.Webhooks.Event

  def index(%{events: events, meta: meta}) do
    %{data: for(event <- events, do: data(event)), meta: meta}
  end

  def show(%{event: event}), do: %{data: data(event)}

  def data(%Event{} = event) do
    %{
      id: event.id,
      event_id: event.event_id,
      subscription_id: event.subscription_id,
      type: event.type,
      status: event.status,
      attempts: event.attempts,
      last_error: event.last_error,
      response_status: event.response_status,
      payload: event.payload,
      delivered_at: event.delivered_at,
      redelivered_at: event.redelivered_at,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end
end
