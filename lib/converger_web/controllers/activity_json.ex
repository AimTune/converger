defmodule ConvergerWeb.ActivityJSON do
  alias Converger.Activities.Activity
  alias Converger.Activities.Serializer

  @doc """
  Renders a list of activities.
  """
  def index(%{activities: activities} = assigns) do
    %{data: for(activity <- activities, do: data(activity))}
    |> put_meta(assigns)
  end

  defp put_meta(body, %{meta: %{} = meta}), do: Map.put(body, :meta, meta)
  defp put_meta(body, _assigns), do: body

  @doc """
  Renders a single activity.
  """
  def show(%{activity: activity}) do
    %{data: data(activity)}
  end

  defp data(%Activity{} = activity), do: Serializer.canonical(activity)
end
