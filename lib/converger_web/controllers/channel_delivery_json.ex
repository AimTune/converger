defmodule ConvergerWeb.ChannelDeliveryJSON do
  alias Converger.Channels.{Channel, Circuit}

  def show(%{channel: channel}) do
    %{data: data(channel)}
  end

  defp data(%Channel{} = channel) do
    %{
      channel_id: channel.id,
      circuit_state: channel.circuit_state,
      circuit_changed_at: channel.circuit_changed_at,
      consecutive_failures: channel.consecutive_failures,
      rate_limit: rate_limit(channel),
      parked_deliveries: Circuit.parked_count(channel.id)
    }
  end

  defp rate_limit(channel) do
    case Circuit.rate_limit_for(channel) do
      {limit, scale_ms} -> %{limit: limit, scale_ms: scale_ms}
      nil -> nil
    end
  end
end
