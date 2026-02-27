defmodule Converger.Channels.Adapters.WebSocket do
  @behaviour Converger.Channels.Adapter

  @impl true
  def validate_config(_config), do: :ok

  @impl true
  def deliver_activity(_channel, _activity) do
    # WebSocket delivery is handled by Phoenix PubSub broadcast in Activities context.
    :ok
  end

  @impl true
  def parse_inbound(_channel, _params) do
    {:error, "websocket channel does not receive inbound webhooks"}
  end
end
