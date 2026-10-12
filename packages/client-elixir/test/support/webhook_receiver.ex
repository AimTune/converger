defmodule ConvergerClient.WebhookReceiver do
  @moduledoc false
  # Plug for the integration test: forwards every webhook request to a pid.
  @behaviour Plug

  @impl true
  def init(test_pid), do: test_pid

  @impl true
  def call(conn, test_pid) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test_pid, {:webhook, conn.req_headers, body})
    Plug.Conn.send_resp(conn, 200, "")
  end
end
