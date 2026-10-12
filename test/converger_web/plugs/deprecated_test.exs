defmodule ConvergerWeb.Plugs.DeprecatedTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ConvergerWeb.Plugs.Deprecated

  @guide "https://converger.aimtune.dev/api/migrating-from-legacy"

  test "adds Deprecation, Sunset and Link headers" do
    opts =
      Deprecated.init(
        deprecated_at: ~U[2026-10-09 00:00:00Z],
        sunset_at: ~U[2027-10-09 00:00:00Z],
        link: @guide
      )

    conn = Deprecated.call(conn(:get, "/"), opts)

    assert get_resp_header(conn, "deprecation") == ["@1791504000"]
    assert get_resp_header(conn, "sunset") == ["Sat, 09 Oct 2027 00:00:00 GMT"]

    assert get_resp_header(conn, "link") == [
             ~s(<#{@guide}>; rel="deprecation", <#{@guide}>; rel="sunset")
           ]
  end

  test "Sunset and Link are optional" do
    conn =
      Deprecated.call(conn(:get, "/"), Deprecated.init(deprecated_at: ~U[2026-10-09 00:00:00Z]))

    assert get_resp_header(conn, "deprecation") == ["@1791504000"]
    assert get_resp_header(conn, "sunset") == []
    assert get_resp_header(conn, "link") == []
  end

  test "init/1 requires DateTimes" do
    assert_raise ArgumentError, fn -> Deprecated.init([]) end

    assert_raise ArgumentError, fn ->
      Deprecated.init(deprecated_at: ~U[2026-10-09 00:00:00Z], sunset_at: "2027")
    end
  end
end
