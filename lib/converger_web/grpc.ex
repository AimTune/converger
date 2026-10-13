defmodule ConvergerWeb.GRPC do
  @moduledoc """
  The gRPC transport of Converger Protocol v1 (ADR-0056,
  docs/protocol/grpc.md): a bidirectional stream per connection, on its own
  port, next to the native WebSocket endpoint.

  Off by default. Configured under `config :converger, ConvergerWeb.GRPC`
  (`GRPC_*` env vars in config/runtime.exs):

      config :converger, ConvergerWeb.GRPC,
        enabled: false,
        port: 50051,
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        # TLS when both are set (h2 over TLS); plaintext h2c otherwise.
        certfile: nil,
        keyfile: nil

  The server is started after the HTTP endpoint and stopped after
  `ConvergerWeb.Drain`, which drains its streams with the native WebSockets
  (`ConvergerWeb.ProtocolConnections`): each gets a `Close` frame with code
  1012 and `retryAfterMs`, then `UNAVAILABLE`.
  """

  alias GRPC.Server.Adapters.ReportException

  @defaults [
    enabled: false,
    port: 50_051,
    ip: {0, 0, 0, 0, 0, 0, 0, 0},
    certfile: nil,
    keyfile: nil
  ]

  @doc "A setting (see the module docs)."
  def config(key) do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc "Whether the gRPC server is enabled."
  def enabled?, do: config(:enabled) == true

  @doc "The supervision children: the gRPC server when enabled, nothing otherwise."
  def child_specs do
    if enabled?(), do: [server_spec(config(:port))], else: []
  end

  @doc false
  # Also used by the tests, which start the endpoint on a random port.
  def server_options do
    [
      adapter_opts: adapter_opts(),
      exception_log_filter: {__MODULE__, :log_exception?}
    ]
  end

  defp server_spec(port) do
    {GRPC.Server.Supervisor,
     [endpoint: ConvergerWeb.GRPC.Endpoint, port: port, start_server: true] ++ server_options()}
  end

  defp adapter_opts do
    # The IPv6 wildcard is dual stack on Linux (as for the HTTP endpoint).
    opts = [ip: config(:ip)]

    case {config(:certfile), config(:keyfile)} do
      {certfile, keyfile} when is_binary(certfile) and is_binary(keyfile) ->
        Keyword.put(opts, :cred, GRPC.Credential.new(ssl: [certfile: certfile, keyfile: keyfile]))

      _ ->
        opts
    end
  end

  @doc """
  Exception log filter of the server: a stream that ends with a close code
  (`GRPC.RPCError` raised by `ConvergerWeb.GRPC.Connection`, e.g. idle
  timeout or draining) is an expected ending, not an error to log.
  """
  def log_exception?(%ReportException{reason: %GRPC.RPCError{}}), do: false
  def log_exception?(_exception), do: true
end
