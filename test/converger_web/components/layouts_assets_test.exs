defmodule ConvergerWeb.LayoutsAssetsTest do
  # The admin/portal JS is bundled by esbuild from deps/ (ADR-0060), so the
  # phoenix and LiveView clients always match the locked server versions.
  # Guard against a layout going back to a CDN copy that can drift.
  use ExUnit.Case, async: true

  @layouts Path.wildcard("lib/converger_web/components/layouts/*.html.heex")

  test "there is a single root layout" do
    assert Enum.map(@layouts, &Path.basename/1) == ["root.html.heex"]
  end

  test "the root layout loads the bundled assets, nothing from a CDN" do
    source = File.read!(hd(@layouts))

    assert source =~ ~s(href={~p"/assets/css/app.css"})
    assert source =~ ~s(src={~p"/assets/js/app.js"})
    refute source =~ ~r{https?://}
  end

  test "app.js imports the phoenix and LiveView clients from deps" do
    source = File.read!("assets/js/app.js")

    assert source =~ ~s(import {Socket} from "phoenix")
    assert source =~ ~s(import {LiveSocket} from "phoenix_live_view")
  end
end
