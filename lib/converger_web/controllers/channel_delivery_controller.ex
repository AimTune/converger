defmodule ConvergerWeb.ChannelDeliveryController do
  @moduledoc """
  Tenant API for a channel's delivery state: circuit breaker, manual
  pause/resume and rate limit (see `Converger.Channels.Circuit`).
  """
  use ConvergerWeb, :controller

  alias Converger.Channels

  plug ConvergerWeb.Plugs.TenantAuth

  action_fallback ConvergerWeb.FallbackController

  def show(conn, %{"channel_id" => id}) do
    channel = Channels.get_channel!(id, conn.assigns.tenant.id)
    render(conn, :show, channel: channel)
  end

  def pause(conn, %{"channel_id" => id}) do
    channel = Channels.get_channel!(id, conn.assigns.tenant.id)
    {:ok, channel} = Channels.pause_deliveries(channel, build_actor(conn))
    render(conn, :show, channel: channel)
  end

  def resume(conn, %{"channel_id" => id}) do
    channel = Channels.get_channel!(id, conn.assigns.tenant.id)
    {:ok, channel} = Channels.resume_deliveries(channel, build_actor(conn))
    render(conn, :show, channel: channel)
  end

  defp build_actor(conn) do
    %{type: "tenant_api", id: conn.assigns.tenant.id}
  end
end
