defmodule ConvergerWeb.Plugs.DbUnavailable do
  @moduledoc """
  Answers `503 Service Unavailable` with `Retry-After` when a request fails
  because the database is unavailable (`Converger.Repo.Pressure.unavailable?/1`:
  the pool is saturated, a query timed out, the connection is gone), instead
  of a `500` and a crash report (issue #35, docs/operations/database.md).

  It wraps the router, `plug ConvergerWeb.Plugs.DbUnavailable, ConvergerWeb.Router`
  in the endpoint, because a plug cannot rescue what later plugs raise. Any
  other exception is re-raised untouched, as is a database error raised after
  the response was sent (a streamed export), which cannot be answered again.

  The body is `{"errors": {"detail": "Service Unavailable", "code":
  "database_unavailable"}}`; `Retry-After` is in whole seconds
  (`Converger.Repo.Pressure.retry_after_ms/0`, rounded up).
  """

  @behaviour Plug

  import Plug.Conn

  alias Converger.Repo.Pressure

  @already_sent {:plug_conn, :sent}

  @impl true
  def init(plug), do: {plug, plug.init([])}

  @impl true
  def call(conn, {plug, opts}) do
    plug.call(conn, opts)
  rescue
    error ->
      if Pressure.unavailable?(error) and not sent?() do
        Pressure.report(:http, unwrap(error))
        unavailable(conn)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp unavailable(conn) do
    retry_after_s = div(Pressure.retry_after_ms() + 999, 1_000)

    body = %{errors: %{detail: "Service Unavailable", code: "database_unavailable"}}

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(503, Jason.encode_to_iodata!(body))
    |> halt()
  end

  # The adapter tells the owner process when a response went out (the same
  # check as Phoenix.Endpoint.RenderErrors).
  defp sent? do
    receive do
      @already_sent ->
        send(self(), @already_sent)
        true
    after
      0 -> false
    end
  end

  defp unwrap(%Plug.Conn.WrapperError{reason: reason}), do: reason
  defp unwrap(error), do: error
end
