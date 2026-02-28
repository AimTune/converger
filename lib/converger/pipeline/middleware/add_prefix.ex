defmodule Converger.Pipeline.Middleware.AddPrefix do
  @moduledoc "Prepends a prefix to the activity text."
  @behaviour Converger.Pipeline.Middleware

  @impl true
  def call(activity, _channel, %{"prefix" => prefix}) when is_binary(prefix) do
    {:cont, %{activity | text: prefix <> (activity.text || "")}}
  end

  def call(activity, _channel, _opts), do: {:cont, activity}

  @impl true
  def validate_opts(%{"prefix" => prefix}) when is_binary(prefix), do: :ok
  def validate_opts(_), do: {:error, "requires \"prefix\" (string)"}
end
