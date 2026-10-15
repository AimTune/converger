defmodule Converger.Channels.OriginsTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.Origins

  describe "normalize/1" do
    test "normalizes like the Origin header" do
      assert Origins.normalize("https://Shop.Example.com/") == {:ok, "https://shop.example.com"}
      assert Origins.normalize("https://example.com:443") == {:ok, "https://example.com"}
      assert Origins.normalize("http://example.com:80") == {:ok, "http://example.com"}
      assert Origins.normalize("http://localhost:5173") == {:ok, "http://localhost:5173"}
      assert Origins.normalize("http://[::1]:5173") == {:ok, "http://[::1]:5173"}
      assert Origins.normalize("https://*.example.com") == {:ok, "https://*.example.com"}
    end

    test "refuses anything that is not a bare origin" do
      for entry <- [
            "*",
            "example.com",
            "ftp://example.com",
            "https://example.com/path",
            "https://example.com?x=1",
            "https://user:pw@example.com",
            "https://*.com",
            "https://a*.example.com",
            "https://*.*.example.com",
            "https://"
          ] do
        assert {:error, _message} = Origins.normalize(entry), "#{entry} was accepted"
      end
    end
  end

  describe "cast_list/1" do
    test "takes text with one origin per line or comma separated" do
      assert Origins.cast_list(
               "https://a.example.com\n\nhttp://localhost:5173, https://A.example.com/"
             ) ==
               {:ok, ["https://a.example.com", "http://localhost:5173"]}

      assert Origins.cast_list(nil) == {:ok, []}
      assert Origins.cast_list([]) == {:ok, []}
    end

    test "names the first invalid entry and caps the list" do
      assert {:error, message} = Origins.cast_list(["https://ok.example.com", "nope"])
      assert message =~ "nope"

      many = for n <- 1..(Origins.max_origins() + 1), do: "https://s#{n}.example.com"
      assert {:error, message} = Origins.cast_list(many)
      assert message =~ "at most"
    end
  end

  describe "allowed?/2" do
    @allowed ["https://shop.example.com", "http://localhost:5173", "https://*.widgets.io"]

    test "matches exact origins" do
      assert Origins.allowed?("https://shop.example.com", @allowed)
      assert Origins.allowed?("https://shop.example.com:443", @allowed)
      assert Origins.allowed?("http://localhost:5173", @allowed)

      refute Origins.allowed?("http://shop.example.com", @allowed)
      refute Origins.allowed?("https://evil.shop.example.com", @allowed)
      refute Origins.allowed?("http://localhost:5174", @allowed)
    end

    test "matches subdomains of a wildcard, not the apex or other schemes and ports" do
      assert Origins.allowed?("https://a.widgets.io", @allowed)
      assert Origins.allowed?("https://a.b.widgets.io", @allowed)

      refute Origins.allowed?("https://widgets.io", @allowed)
      refute Origins.allowed?("https://evilwidgets.io", @allowed)
      refute Origins.allowed?("http://a.widgets.io", @allowed)
      refute Origins.allowed?("https://a.widgets.io:8443", @allowed)
    end

    test "never matches a wildcard or malformed request origin" do
      refute Origins.allowed?("https://*.widgets.io", @allowed)
      refute Origins.allowed?("null", @allowed)
      refute Origins.allowed?(nil, @allowed)
      refute Origins.allowed?("https://shop.example.com", [])
    end
  end
end
