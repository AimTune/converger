defmodule Converger.HTTPTest do
  use ExUnit.Case, async: true

  test "runs requests through Req with OpenTelemetry attached" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, %Req.Response{status: 200, body: %{"ok" => true}}} =
             Converger.HTTP.post("http://example.test/hook",
               json: %{},
               plug: {Req.Test, __MODULE__},
               propagate_trace_headers: true
             )
  end
end
