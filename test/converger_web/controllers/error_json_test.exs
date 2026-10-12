defmodule ConvergerWeb.ErrorJSONTest do
  use ConvergerWeb.ConnCase, async: true

  alias ConvergerWeb.ErrorJSON

  test "renders 404 in the error envelope" do
    assert ErrorJSON.render("404.json", %{}) ==
             %{error: %{code: "not_found", message: "Not found", details: nil, request_id: nil}}
  end

  test "renders 500 without leaking the exception" do
    assert %{error: %{code: "internal", message: "Internal server error"}} =
             ErrorJSON.render("500.json", %{})
  end

  test "maps statuses to codes and carries the request id" do
    conn = Plug.Conn.put_resp_header(build_conn(), "x-request-id", "req-1")

    for {status, code} <- [
          {400, "bad_request"},
          {401, "unauthorized"},
          {403, "forbidden"},
          {406, "not_acceptable"},
          {413, "payload_too_large"},
          {415, "unsupported_media_type"},
          {418, "bad_request"},
          {503, "unavailable"},
          {504, "internal"}
        ] do
      assert %{error: %{code: ^code, request_id: "req-1"}} =
               ErrorJSON.render("#{status}.json", %{conn: conn})
    end
  end
end
