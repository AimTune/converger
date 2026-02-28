defmodule Converger.Pipeline.Middleware.AddSuffix do
  @moduledoc "Appends a suffix to the activity text."
  @behaviour Converger.Pipeline.Middleware

  @impl true
  def call(activity, _channel, %{"suffix" => suffix}) when is_binary(suffix) do
    {:cont, %{activity | text: (activity.text || "") <> suffix}}
  end

  def call(activity, _channel, _opts), do: {:cont, activity}

  @impl true
  def validate_opts(%{"suffix" => suffix}) when is_binary(suffix), do: :ok
  def validate_opts(_), do: {:error, "requires \"suffix\" (string)"}
end
