defmodule Converger.Test.Middleware.Crashing do
  @moduledoc "Test-only middleware that always raises."
  @behaviour Converger.Pipeline.Middleware

  @impl true
  def call(_activity, _channel, _opts), do: raise("boom")

  @impl true
  def validate_opts(_opts), do: :ok
end
