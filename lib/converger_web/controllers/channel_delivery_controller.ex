defmodule ConvergerWeb.ChannelDeliveryController do
  @moduledoc """
  Tenant API for a channel's delivery state: circuit breaker, manual
  pause/resume and rate limit (see `Converger.Channels.Circuit`).
  """
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Channels

  # Pausing and resuming a channel is a channel change: `manage` (ADR-0061).
  plug ConvergerWeb.Plugs.TenantAuth, scopes: [pause: "manage", resume: "manage"]

  action_fallback ConvergerWeb.FallbackController

  tags(["Channels"])
  security([%{"apiKey" => []}, %{"channelToken" => []}])

  @state_responses with_errors(
                     %{
                       200 =>
                         json_schema("The delivery state", ref("ChannelDeliveryStateResponse"))
                     },
                     [400, 401, 404]
                   )

  operation(:show,
    summary: "Get a channel's delivery state",
    operation_id: "getChannelDeliveryState",
    parameters: [channel_id: path_id("Channel id")],
    responses: @state_responses
  )

  operation(:pause,
    summary: "Pause a channel's deliveries",
    description: "Parks new and pending deliveries until resumed. Idempotent.",
    operation_id: "pauseChannelDeliveries",
    parameters: [channel_id: path_id("Channel id")],
    responses: @state_responses
  )

  operation(:resume,
    summary: "Resume a channel's deliveries",
    description: "Closes the breaker and releases parked deliveries. Idempotent.",
    operation_id: "resumeChannelDeliveries",
    parameters: [channel_id: path_id("Channel id")],
    responses: @state_responses
  )

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

  defp build_actor(conn), do: ConvergerWeb.Plugs.TenantAuth.actor(conn)
end
