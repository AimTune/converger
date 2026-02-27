defmodule Converger.ChannelsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Converger.Channels` context.
  """

  def unique_channel_name, do: "Channel #{System.unique_integer()}"

  def channel_fixture(tenant, attrs \\ %{}) do
    {:ok, channel} =
      attrs
      |> Enum.into(%{
        name: unique_channel_name(),
        type: "echo",
        status: "active",
        tenant_id: tenant.id
      })
      |> Converger.Channels.create_channel()

    channel
  end
end
