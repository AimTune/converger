defmodule Converger.ConversationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Converger.Conversations` context.
  """

  def conversation_fixture(tenant, channel, attrs \\ %{}) do
    {:ok, conversation} =
      attrs
      |> Enum.into(%{
        status: "active",
        tenant_id: tenant.id,
        channel_id: channel.id
      })
      |> Converger.Conversations.create_conversation()

    conversation
  end
end
