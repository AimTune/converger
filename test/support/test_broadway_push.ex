defmodule Converger.TestBroadwayPush do
  @moduledoc """
  Broadway `:custom` push module for tests. Instead of publishing to a broker
  it sends `{:broadway_push, message}` to the calling process, so a test can
  feed the message through `Converger.Pipeline.Broadway.Pipeline` itself.
  """

  @behaviour Converger.Pipeline.Broadway.PushBehaviour

  @impl true
  def push(message, _opts) do
    send(self(), {:broadway_push, message})
    :ok
  end
end
