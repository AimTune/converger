defmodule Converger.ChannelsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Converger.Channels` context.
  """

  def unique_channel_name, do: "Channel #{System.unique_integer()}"

  def channel_fixture(tenant, attrs \\ %{}) do
    attrs = Map.new(attrs)
    # `echo` is outbound-only; websocket channels default to duplex like new channels.
    mode = if attrs[:type] == "echo", do: "outbound", else: "duplex"

    {:ok, channel} =
      attrs
      |> Enum.into(%{
        name: unique_channel_name(),
        type: "websocket",
        mode: mode,
        status: "active",
        tenant_id: tenant.id
      })
      |> Converger.Channels.create_channel()

    channel
  end

  def webhook_channel_fixture(tenant, attrs \\ %{}) do
    {:ok, channel} =
      attrs
      |> Enum.into(%{
        name: unique_channel_name(),
        type: "webhook",
        mode: "duplex",
        status: "active",
        config: %{"url" => "https://example.com/webhook"},
        tenant_id: tenant.id
      })
      |> Converger.Channels.create_channel()

    channel
  end
end
