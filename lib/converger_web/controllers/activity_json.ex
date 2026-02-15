defmodule ConvergerWeb.ActivityJSON do
  alias Converger.Activities.Activity

  @doc """
  Renders a list of activities.
  """
  def index(%{activities: activities}) do
    %{data: for(activity <- activities, do: data(activity))}
  end

  @doc """
  Renders a single activity.
  """
  def show(%{activity: activity}) do
    %{data: data(activity)}
  end

  defp data(%Activity{} = activity) do
    %{
      id: activity.id,
      type: activity.type,
      sender: activity.sender,
      text: activity.text,
      attachments: activity.attachments,
      metadata: activity.metadata,
      idempotency_key: activity.idempotency_key,
      conversation_id: activity.conversation_id,
      tenant_id: activity.tenant_id,
      inserted_at: activity.inserted_at
    }
  end
end
