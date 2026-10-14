defmodule ConvergerWeb.ProtocolConfig do
  @moduledoc """
  Overrides `config :converger, ConvergerWeb.Protocol` settings for one test.

  Only the given keys change and the previous settings are restored when the
  test exits. Replacing or deleting the whole env instead dropped the test
  config (`group_settle_ms`, ...) for every later test and made them flaky.
  """

  @doc "Merge `settings` into the protocol config until the test exits."
  def put(settings) when is_list(settings) do
    previous = Application.get_env(:converger, ConvergerWeb.Protocol, [])
    Application.put_env(:converger, ConvergerWeb.Protocol, Keyword.merge(previous, settings))

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:converger, ConvergerWeb.Protocol, previous)
    end)
  end
end
