defmodule Converger.ActivitiesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Converger.Activities` context.
  """

  def activity_fixture(tenant, conversation, attrs \\ %{}) do
    {:ok, activity} =
      attrs
      |> Enum.into(%{
        type: "message",
        sender: "user-1",
        text: "some content",
        tenant_id: tenant.id,
        conversation_id: conversation.id
      })
      |> Converger.Activities.create_activity()

    activity
  end
end
