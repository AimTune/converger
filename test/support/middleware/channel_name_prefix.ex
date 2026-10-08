defmodule Converger.Test.Middleware.ChannelNamePrefix do
  @moduledoc "Test-only middleware that prefixes the text with the channel name."
  @behaviour Converger.Pipeline.Middleware

  @impl true
  def call(activity, %Converger.Channels.Channel{name: name}, _opts) do
    {:cont, %{activity | text: "[#{name}] #{activity.text}"}}
  end

  @impl true
  def validate_opts(_opts), do: :ok
end
