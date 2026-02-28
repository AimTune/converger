defmodule Converger.Pipeline.Middleware.TextReplace do
  @moduledoc "Replaces occurrences of a pattern in the activity text."
  @behaviour Converger.Pipeline.Middleware

  @impl true
  def call(activity, _channel, %{"pattern" => pattern, "replacement" => replacement})
      when is_binary(pattern) and is_binary(replacement) do
    updated_text = String.replace(activity.text || "", pattern, replacement)
    {:cont, %{activity | text: updated_text}}
  end

  def call(activity, _channel, _opts), do: {:cont, activity}

  @impl true
  def validate_opts(%{"pattern" => p, "replacement" => r})
      when is_binary(p) and is_binary(r),
      do: :ok

  def validate_opts(_), do: {:error, "requires \"pattern\" and \"replacement\" (strings)"}
end
