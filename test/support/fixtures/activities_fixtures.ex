defmodule Converger.ActivitiesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Converger.Activities` context.
  """

  import Ecto.Query

  @doc """
  Creates an activity. `inserted_at` cannot be set through the changeset
  (the server timestamp always wins), so a given `:inserted_at` is applied
  directly to the row afterwards to backdate test data.
  """
  def activity_fixture(tenant, conversation, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {inserted_at, attrs} = Map.pop(attrs, :inserted_at)

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

    if inserted_at do
      from(a in Converger.Activities.Activity, where: a.id == ^activity.id)
      |> Converger.Repo.update_all(set: [inserted_at: inserted_at])

      # Deliveries the pipeline already created follow their activity's partition.
      from(d in Converger.Deliveries.Delivery, where: d.activity_id == ^activity.id)
      |> Converger.Repo.update_all(set: [activity_inserted_at: inserted_at])

      Converger.Repo.reload!(activity)
    else
      activity
    end
  end
end
