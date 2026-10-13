defmodule Converger.PaginationContainsTest do
  use ExUnit.Case, async: true

  alias Converger.Pagination

  doctest Converger.Pagination, only: [contains: 1]

  test "contains/1 escapes LIKE wildcards and the escape character" do
    assert Pagination.contains(~S"a\b") == ~S"%a\\b%"
    assert Pagination.contains("acme") == "%acme%"
    assert Pagination.contains(nil) == nil
  end
end
