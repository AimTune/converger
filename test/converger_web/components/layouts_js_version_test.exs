defmodule ConvergerWeb.LayoutsJSVersionTest do
  # The layouts load phoenix.js and phoenix_live_view.js from a CDN. The
  # client must match the server version, so fail when a dependency upgrade
  # leaves the pinned CDN versions behind.
  use ExUnit.Case, async: true

  @layouts Path.wildcard("lib/converger_web/components/layouts/*root.html.heex")

  defp vsn(app), do: app |> Application.spec(:vsn) |> to_string()

  test "layouts exist" do
    assert length(@layouts) == 3
  end

  for layout <- @layouts do
    @layout layout

    test "#{Path.basename(layout)} loads the locked phoenix and phoenix_live_view JS" do
      source = File.read!(@layout)

      assert source =~ "npm/phoenix@#{vsn(:phoenix)}/priv/static/phoenix.min.js"

      assert source =~
               "npm/phoenix_live_view@#{vsn(:phoenix_live_view)}/priv/static/phoenix_live_view.min.js"
    end
  end
end
