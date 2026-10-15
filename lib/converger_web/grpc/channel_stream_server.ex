defmodule ConvergerWeb.GRPC.ChannelStreamServer do
  @moduledoc """
  The gRPC service `converger.v1.ChannelStream` (ADR-0056,
  docs/protocol/grpc.md): `Connect(stream ClientFrame) returns (stream
  ServerFrame)` is one Converger Protocol v1 connection to one conversation,
  the transport alternative to the native WebSocket endpoint for backend
  clients.

  The credential is the `authorization: Bearer <converger token>` metadata
  or `Hello.token`, checked on `hello` as on the WebSocket. While the node
  drains, new streams are refused with `UNAVAILABLE`. The connection itself
  is `ConvergerWeb.GRPC.Connection`.
  """

  use GRPC.Server,
    service: Converger.V1.ChannelStream.Service,
    codecs: [GRPC.Codec.Proto, GRPC.Codec.JSON]

  alias ConvergerWeb.{Drain, SocketGuard}
  alias ConvergerWeb.GRPC.Connection

  @doc false
  def connect(requests, stream) do
    if Drain.draining?() do
      SocketGuard.emit(:draining, __MODULE__)

      raise GRPC.RPCError,
        status: :unavailable,
        message:
          "the node is draining, reconnect later (retryAfterMs #{SocketGuard.retry_after_ms()})"
    end

    # The request enumerable is not used: Connection reads the request body
    # itself, to enforce the frame size cap before buffering a message.
    _ = requests
    Connection.run(stream, credential(stream.http_request_headers))
  end

  defp credential(headers) do
    case Map.get(headers, "authorization") do
      "Bearer " <> token -> if String.trim(token) != "", do: String.trim(token)
      _ -> nil
    end
  end
end
