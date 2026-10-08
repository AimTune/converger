defmodule Converger.ApplicationObanConfigTest do
  # Mutates application env.
  use ExUnit.Case, async: false

  setup do
    oban = Application.fetch_env!(:converger, Oban)
    lifeline = Application.get_env(:converger, :oban_lifeline)

    on_exit(fn ->
      Application.put_env(:converger, Oban, oban)

      if lifeline,
        do: Application.put_env(:converger, :oban_lifeline, lifeline),
        else: Application.delete_env(:converger, :oban_lifeline)
    end)

    Application.put_env(:converger, Oban,
      repo: Converger.Repo,
      plugins: [
        {Oban.Plugins.Pruner, max_age: 60},
        {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
      ]
    )

    :ok
  end

  test "without overrides the configured Lifeline is kept" do
    Application.delete_env(:converger, :oban_lifeline)

    assert Converger.Application.oban_config() == Application.fetch_env!(:converger, Oban)
  end

  test "overrides are merged into the Lifeline plugin only" do
    Application.put_env(:converger, :oban_lifeline, rescue_after: 30_000, interval: 10_000)

    plugins = Keyword.fetch!(Converger.Application.oban_config(), :plugins)

    assert {Oban.Plugins.Pruner, [max_age: 60]} in plugins

    assert {Oban.Plugins.Lifeline, opts} = List.keyfind(plugins, Oban.Plugins.Lifeline, 0)
    assert opts[:rescue_after] == 30_000
    assert opts[:interval] == 10_000
  end

  test "plugins disabled (false) stay disabled" do
    Application.put_env(:converger, Oban, repo: Converger.Repo, plugins: false)
    Application.put_env(:converger, :oban_lifeline, rescue_after: 30_000)

    assert Keyword.fetch!(Converger.Application.oban_config(), :plugins) == false
  end
end
