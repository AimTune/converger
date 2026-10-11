defmodule Converger.TestCluster.WebhookSink do
  @moduledoc """
  Plug for a throwaway HTTP server (Bandit) that receives the webhook
  deliveries of the multi-node suite. Every request is sent to the test
  process as `{:webhook, decoded_body, headers}` and answered with `200`.
  """

  @behaviour Plug

  @impl true
  def init(test_pid) when is_pid(test_pid), do: test_pid

  @impl true
  def call(conn, test_pid) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test_pid, {:webhook, Jason.decode!(body), conn.req_headers})
    Plug.Conn.send_resp(conn, 200, "ok")
  end
end
