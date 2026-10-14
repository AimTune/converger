defmodule ConvergerWeb.ProtocolSocket do
  @moduledoc """
  The native Converger Protocol v1 WebSocket endpoint (docs/protocol/v1.md,
  section 2.1): `GET /socket/converger/v1`, raw v1 frames with no Phoenix
  Channels framing, one frame per WebSocket message.

  This is a `WebSock` handler, upgraded to by `ConvergerWeb.ProtocolSocketController`
  (which also negotiates the subprotocol, and with it the encoding). One
  process serves one connection to one conversation. The protocol itself
  (handshake, replay, acks, receipts, limits, draining) is
  `ConvergerWeb.Protocol.Session`, shared with the gRPC transport
  (`ConvergerWeb.GRPC.ChannelStreamServer`); this module only decodes and
  encodes WebSocket messages (`ConvergerWeb.Protocol.Codec`) and maps a
  session close to a WebSocket close.

  A client that negotiated no subprotocol and names no `hello.protocol` is
  a mekik/1 client and gets the mekik/1 profile of the frames
  (`ConvergerWeb.Protocol.MekikProfile`, ADR-0065): no Converger-only
  transient frames, and heartbeats as WebSocket pings.

  1012 (draining) and 4503 (slow consumer) closes carry the JSON close reason
  `{"reason": ..., "retryAfterMs": N}` (`ConvergerWeb.SocketGuard`). A frame
  above the hard cap (`:websocket_max_frame_size`) is refused by Bandit with
  1009.
  """

  @behaviour WebSock

  alias ConvergerWeb.Protocol.{Codec, MekikProfile, Session}

  @impl WebSock
  def init(opts) do
    session =
      Session.new(transport: "websocket", handler: __MODULE__, token: Keyword.get(opts, :token))

    {:ok,
     %{
       session: session,
       encoding: Keyword.fetch!(opts, :encoding),
       subprotocol: Keyword.get(opts, :subprotocol)
     }}
  end

  @impl WebSock
  def handle_in({data, opcode: opcode}, state) do
    decode = fn -> Codec.decode(data, opcode, state.encoding) end

    data
    |> byte_size()
    |> Session.handle_in(decode, state.session)
    |> result(state)
  end

  @impl WebSock
  def handle_control({_data, opcode: _opcode}, state),
    do: {:ok, %{state | session: Session.touch(state.session)}}

  @impl WebSock
  def handle_info(message, state),
    do: message |> Session.handle_info(state.session) |> result(state)

  @impl WebSock
  def terminate(reason, state), do: Session.terminate(reason, state.session)

  defp result({:ok, session}, state), do: {:ok, %{state | session: session}}

  # Frames are encoded with the session they leave (after `hello`, it knows
  # the client's `hello.protocol`).
  defp result({:push, frames, session}, state) do
    state = %{state | session: session}
    {:push, encode(frames, state), state}
  end

  defp result({:close, close, [], session}, state),
    do: {:stop, :normal, close_detail(close), %{state | session: session}}

  defp result({:close, close, frames, session}, state) do
    state = %{state | session: session}
    {:stop, :normal, close_detail(close), encode(frames, state), state}
  end

  defp encode(frames, state) do
    frames =
      if MekikProfile.active?(state.subprotocol, Session.protocol(state.session)),
        do: MekikProfile.frames(frames),
        else: frames

    Enum.map(frames, fn
      :ping -> {:ping, ""}
      frame -> Codec.encode(frame, state.encoding)
    end)
  end

  defp close_detail(%{code: code, reason: reason, retry_after_ms: nil}), do: {code, reason}

  defp close_detail(%{code: code, reason: reason, retry_after_ms: retry_after_ms}),
    do: {code, Jason.encode!(%{reason: reason, retryAfterMs: retry_after_ms})}
end
