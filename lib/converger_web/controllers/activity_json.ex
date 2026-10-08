defmodule ConvergerWeb.ActivityJSON do
  alias Converger.Activities.Activity
  alias Converger.Activities.Serializer

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

  defp data(%Activity{} = activity), do: Serializer.canonical(activity)
end
