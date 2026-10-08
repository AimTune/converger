defmodule ConvergerWeb.CheckOriginConfigTest do
  # Guards the Sobelow `Config.CSWH` ignore in .sobelow-conf: WebSocket origin
  # checking may only be disabled for local development.
  use ExUnit.Case, async: true

  test "check_origin is never disabled outside config/dev.exs" do
    offenders =
      for path <- Path.wildcard("config/*.exs"),
          Path.basename(path) != "dev.exs",
          File.read!(path) =~ ~r/check_origin:\s*false/,
          do: path

    assert offenders == []
  end

  test "CHECK_ORIGIN can only narrow origins to an explicit non-empty list" do
    source = File.read!("config/runtime.exs")
    assert source =~ ~s|System.get_env("CHECK_ORIGIN")|
    assert source =~ "contains no origins"
  end
end
