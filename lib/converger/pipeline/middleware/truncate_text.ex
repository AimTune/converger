defmodule Converger.Pipeline.Middleware.TruncateText do
  @moduledoc "Truncates activity text to a maximum length."
  @behaviour Converger.Pipeline.Middleware

  @impl true
  def call(activity, _channel, %{"max_length" => max_length} = opts)
      when is_integer(max_length) and max_length > 0 do
    text = activity.text || ""
    ellipsis = Map.get(opts, "ellipsis", "...")

    if String.length(text) > max_length do
      truncated = String.slice(text, 0, max_length) <> ellipsis
      {:cont, %{activity | text: truncated}}
    else
      {:cont, activity}
    end
  end

  def call(activity, _channel, _opts), do: {:cont, activity}

  @impl true
  def validate_opts(%{"max_length" => n}) when is_integer(n) and n > 0, do: :ok
  def validate_opts(_), do: {:error, "requires \"max_length\" (positive integer)"}
end
