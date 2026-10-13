defmodule ConvergerWeb.GRPC.Connection do
  @moduledoc """
  One `ChannelStream.Connect` stream: a Converger Protocol v1 session
  (`ConvergerWeb.Protocol.Session`) carried by a gRPC bidirectional stream.

  It runs in the RPC process of the gRPC server, which becomes the session
  process: it subscribes to the conversation, receives the PubSub
  broadcasts, the heartbeat tick, token expiry and drain messages, and sends
  every server frame with `GRPC.Server.send_reply/2`
  (`ConvergerWeb.GRPC.Frames` maps the JSON frames to protobuf).

  Client frames are read by a linked reader process, one message at a time:
  the next message is read only after the session handled the previous one,
  so a client that sends faster than the session works is held back by
  HTTP/2 flow control. The reader checks the gRPC message length prefix
  against the hard frame cap (`:websocket_max_frame_size`, 1 MiB) before
  buffering the message, the equivalent of WebSocket close 1009.

  Endings:

    * the session closes (close codes of docs/protocol/v1.md, section 12.3):
      its last frames, then a `Close` frame with the code, then the RPC ends
      with the matching gRPC status (`status/1`);
    * the client half-closes its side: the session ends with `OK`;
    * the client cancels or the connection drops: the session ends.
  """

  require Logger

  alias ConvergerWeb.GRPC.Frames
  alias ConvergerWeb.Protocol.Session
  alias ConvergerWeb.SocketGuard
  alias GRPC.Server.Adapters.Cowboy.Handler

  @handler ConvergerWeb.GRPC.ChannelStreamServer

  # WebSocket close code => gRPC status of the RPC that ends with it.
  @statuses %{
    1000 => :ok,
    1008 => :not_found,
    1009 => :resource_exhausted,
    1012 => :unavailable,
    1013 => :unavailable,
    4400 => :failed_precondition,
    4401 => :unauthenticated,
    4403 => :permission_denied,
    4408 => :deadline_exceeded,
    4503 => :resource_exhausted
  }

  @doc "The gRPC status a stream ends with after the WebSocket close `code`."
  @spec status(pos_integer()) :: atom()
  def status(code), do: Map.get(@statuses, code, :aborted)

  @doc "Serves the stream until it ends. Runs in the RPC process."
  @spec run(GRPC.Server.Stream.t(), String.t() | nil) :: :ok
  def run(stream, token) do
    # The stream (cowboy) process is linked: its exit (client cancel,
    # connection lost) arrives as a message, so the session is cleaned up.
    Process.flag(:trap_exit, true)
    stream_pid = stream.payload.pid
    owner = self()
    hard_cap = Application.fetch_env!(:converger, :websocket_max_frame_size)
    reader = spawn_link(fn -> read(stream, owner, hard_cap) end)

    session =
      Session.new(
        transport: "grpc",
        handler: @handler,
        token: token,
        # Frames waiting in this process, plus the replies the stream
        # process has not written to the connection yet.
        backlog: fn ->
          max(SocketGuard.queue_len(self()), SocketGuard.queue_len(stream_pid))
        end
      )

    state = %{stream: stream, stream_pid: stream_pid, reader: reader, session: session}

    try do
      loop(state)
    after
      Process.unlink(reader)
      Process.exit(reader, :kill)
    end
  end

  defp loop(%{reader: reader, stream_pid: stream_pid} = state) do
    receive do
      {:grpc_frame, ^reader, size, decoded} ->
        send(reader, :grpc_next)

        size
        |> Session.handle_in(fn -> decoded end, state.session)
        |> handle(state)

      {:grpc_half_close, ^reader} ->
        end_stream(%{code: 1000, reason: "client closed", retry_after_ms: nil}, [], state)

      {:grpc_too_large, ^reader, size} ->
        SocketGuard.emit(:frame_too_large, @handler)
        Logger.info("gRPC stream closed: a #{size} byte message is above the hard cap")
        end_stream(%{code: 1009, reason: "frame too large", retry_after_ms: nil}, [], state)

      {:EXIT, ^stream_pid, reason} ->
        Session.terminate(reason, state.session)

      {:EXIT, ^reader, reason} ->
        Logger.warning("gRPC stream reader failed", reason: inspect(reason))
        Session.terminate(reason, state.session)
        raise GRPC.RPCError, status: :internal, message: "the stream could not be read"

      {:EXIT, _pid, _reason} ->
        loop(state)

      message ->
        message
        |> Session.handle_info(state.session)
        |> handle(state)
    end
  end

  defp handle({:ok, session}, state), do: loop(%{state | session: session})

  defp handle({:push, frames, session}, state) do
    push(frames, state)
    loop(%{state | session: session})
  end

  defp handle({:close, close, frames, session}, state),
    do: end_stream(close, frames, %{state | session: session})

  defp end_stream(close, frames, state) do
    push(frames, state)

    GRPC.Server.send_reply(
      state.stream,
      Frames.close(close.code, close.reason, close.retry_after_ms)
    )

    Session.terminate(:normal, state.session)

    case status(close.code) do
      :ok -> :ok
      status -> raise GRPC.RPCError, status: status, message: close.reason
    end
  end

  defp push(frames, state) do
    Enum.each(frames, &GRPC.Server.send_reply(state.stream, Frames.to_server_frame(&1)))
  end

  ## Reader (a linked process)

  defp read(stream, owner, hard_cap), do: read(stream, owner, hard_cap, <<>>, false)

  defp read(stream, owner, hard_cap, buffer, fin?) do
    case next_message(buffer, hard_cap) do
      {:message, flag, data, rest} ->
        send(owner, {:grpc_frame, self(), byte_size(data), decode(stream, flag, data)})

        receive do
          :grpc_next -> read(stream, owner, hard_cap, rest, fin?)
        end

      {:too_large, size} ->
        send(owner, {:grpc_too_large, self(), size})

      :incomplete when fin? ->
        send(owner, {:grpc_half_close, self()})

      :incomplete ->
        case Handler.read_body(stream.payload.pid) do
          {:ok, data} -> read(stream, owner, hard_cap, buffer <> data, true)
          {:more, data} -> read(stream, owner, hard_cap, buffer <> data, false)
        end
    end
  end

  # gRPC length-prefixed message: 1 byte compressed flag, 4 bytes length.
  defp next_message(<<_flag, size::32, _rest::binary>>, hard_cap) when size > hard_cap,
    do: {:too_large, size}

  defp next_message(<<flag, size::32, data::binary-size(size), rest::binary>>, _hard_cap),
    do: {:message, flag, data, rest}

  defp next_message(_buffer, _hard_cap), do: :incomplete

  defp decode(stream, flag, data) do
    with {:ok, data} <- decompress(stream, flag, data) do
      frame = stream.codec.decode(data, Converger.V1.ClientFrame)
      {:ok, Frames.from_client_frame(frame)}
    end
  rescue
    _error -> {:error, "malformed protobuf ClientFrame"}
  end

  defp decompress(_stream, 0, data), do: {:ok, data}

  defp decompress(%{compressor: nil}, _flag, _data),
    do: {:error, "compressed message without grpc-encoding"}

  defp decompress(%{compressor: compressor}, _flag, data), do: {:ok, compressor.decompress(data)}
end
