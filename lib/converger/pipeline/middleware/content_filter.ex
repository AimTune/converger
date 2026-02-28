defmodule Converger.Pipeline.Middleware.ContentFilter do
  @moduledoc "Blocks delivery if the activity text matches any of the given patterns."
  @behaviour Converger.Pipeline.Middleware

  @impl true
  def call(activity, _channel, %{"block_patterns" => patterns}) when is_list(patterns) do
    text = activity.text || ""

    if Enum.any?(patterns, &String.contains?(text, &1)) do
      {:halt, "content blocked by filter"}
    else
      {:cont, activity}
    end
  end

  def call(activity, _channel, _opts), do: {:cont, activity}

  @impl true
  def validate_opts(%{"block_patterns" => patterns}) when is_list(patterns) do
    if Enum.all?(patterns, &is_binary/1) do
      :ok
    else
      {:error, "all block_patterns must be strings"}
    end
  end

  def validate_opts(_), do: {:error, "requires \"block_patterns\" (list of strings)"}
end
