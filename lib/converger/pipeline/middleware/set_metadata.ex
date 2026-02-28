defmodule Converger.Pipeline.Middleware.SetMetadata do
  @moduledoc "Merges key/value pairs into the activity metadata."
  @behaviour Converger.Pipeline.Middleware

  @impl true
  def call(activity, _channel, %{"values" => values}) when is_map(values) do
    updated_metadata = Map.merge(activity.metadata || %{}, values)
    {:cont, %{activity | metadata: updated_metadata}}
  end

  def call(activity, _channel, _opts), do: {:cont, activity}

  @impl true
  def validate_opts(%{"values" => values}) when is_map(values), do: :ok
  def validate_opts(_), do: {:error, "requires \"values\" (map)"}
end
