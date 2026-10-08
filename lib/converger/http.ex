defmodule Converger.HTTP do
  @moduledoc """
  Outbound HTTP through `Req`, traced with `OpentelemetryReq`.

  Calls made through `request/1` produce an OpenTelemetry client span under
  the current span (e.g. the Oban job or pipeline span). Pass
  `propagate_trace_headers: true` to also send W3C `traceparent` headers to
  the remote end (used for tenant webhooks, which may continue the trace).
  """

  @doc "Builds a request from `Req` options, attaches tracing and runs it."
  @spec request(keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(options) do
    {propagate, options} = Keyword.pop(options, :propagate_trace_headers, false)

    options
    |> Req.new()
    |> OpentelemetryReq.attach(propagate_trace_headers: propagate)
    |> Req.request()
  end

  @doc "POST shortcut for `request/1`."
  @spec post(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def post(url, options), do: request([method: :post, url: url] ++ options)
end
