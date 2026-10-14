defmodule ConvergerWeb.Protocol.MekikProfile do
  @moduledoc """
  The mekik/1 profile of the native endpoint (docs/protocol/v1.md section
  14.1, ADR-0065).

  Converger Protocol v1 is a superset of mekik/1, but mekik/1 has an open
  rule (mekik/1 section 4.5): a frame type a client does not know is a rich
  message, rendered by name. An unmodified mekik/1 client, such as chativa's
  `@chativa/connector-mekik`, therefore shows Converger's additive transient
  frames (`ack`, `deliveryStatus`, ...) as chat bubbles instead of ignoring
  them.

  A connection is a mekik/1 client when it negotiated **no** WebSocket
  subprotocol and its `hello` has no `protocol` (or `"mekik/1"`). For such a
  connection the server:

    * does not send the Converger-only transient frames (`ack`,
      `deliveryStatus`, `presence`, `tokenRefreshed`, `replayTruncated`);
    * sends `heartbeat` as a WebSocket ping instead, so the client's
      automatic pong keeps the connection inside the idle timeout;
    * reports `token_expired` and `token_revoked` with the mekik/1 auth code
      `unauthorized` (the `number` keeps the Converger code), so a mekik
      client's auth provider can fetch a fresh token and reconnect.

  Everything else, persistent frames included, is sent unchanged. A client
  that offers the `converger.v1` subprotocol or sends `hello.protocol:
  "converger/1"` gets the full protocol.
  """

  @converger_only ~w(ack deliveryStatus presence tokenRefreshed replayTruncated)
  @auth_codes ~w(token_expired token_revoked)

  @doc "The transient frame types a mekik/1 client does not receive."
  def converger_only, do: @converger_only

  @doc """
  Whether a connection speaks the mekik/1 profile: `subprotocol` is the
  negotiated WebSocket subprotocol (nil when none), `protocol` the
  `hello.protocol` (nil when absent or before `hello`).
  """
  @spec active?(String.t() | nil, String.t() | nil) :: boolean()
  def active?(subprotocol, protocol), do: is_nil(subprotocol) and protocol in [nil, "mekik/1"]

  @doc """
  The frames for a mekik/1 client: Converger-only transient frames removed,
  `heartbeat` replaced by `:ping` (a WebSocket ping), auth errors renamed.
  """
  @spec frames([map()]) :: [map() | :ping]
  def frames(frames), do: Enum.flat_map(frames, &frame/1)

  # Frames are string-keyed (ConvergerWeb.Protocol.Frames) or, for receipts,
  # typing and presence, atom-keyed (ConvergerWeb.ConvergerFrames).
  defp frame(frame) do
    case Map.get(frame, "type", Map.get(frame, :type)) do
      type when type in @converger_only -> []
      "heartbeat" -> [:ping]
      "error" -> [auth_error(frame)]
      _type -> [frame]
    end
  end

  defp auth_error(%{"data" => %{"code" => code} = data} = frame) when code in @auth_codes,
    do: %{frame | "data" => %{data | "code" => "unauthorized"}}

  defp auth_error(frame), do: frame
end
