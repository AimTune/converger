defmodule ConvergerWeb.Plugs.DbUnavailableTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias ConvergerWeb.Plugs.DbUnavailable

  @moduletag :capture_log

  defmodule FakeRouter do
    @behaviour Plug

    alias Plug.Conn.WrapperError

    def init(opts), do: opts

    def call(%{path_info: ["pool"]} = conn, _opts) do
      error = DBConnection.ConnectionError.exception("dropped from queue")
      # As Phoenix.Router does.
      WrapperError.reraise(conn, :error, error, [])
    end

    def call(%{path_info: ["bare"]}, _opts),
      do: raise(DBConnection.ConnectionError, "connection closed")

    def call(%{path_info: ["boom"]}, _opts), do: raise("boom")

    def call(%{path_info: ["streamed"]} = conn, _opts) do
      conn = send_chunked(conn, 200)
      {:ok, _conn} = chunk(conn, "partial")
      raise DBConnection.ConnectionError, "query timed out"
    end

    def call(conn, _opts), do: send_resp(conn, 200, "ok")
  end

  defp call(path), do: conn(:get, path) |> DbUnavailable.call(DbUnavailable.init(FakeRouter))

  test "passes through when nothing fails" do
    assert call("/fine").status == 200
  end

  test "a connection error, wrapped by the router or not, is 503 with Retry-After" do
    for path <- ["/pool", "/bare"] do
      conn = call(path)

      assert conn.status == 503
      assert conn.halted
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
      assert Jason.decode!(conn.resp_body)["errors"]["code"] == "database_unavailable"
    end
  end

  test "any other exception is re-raised" do
    assert_raise RuntimeError, "boom", fn -> call("/boom") end
  end

  test "an error after the response was sent is re-raised" do
    assert_raise DBConnection.ConnectionError, fn -> call("/streamed") end
  end
end
