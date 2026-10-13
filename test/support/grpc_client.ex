defmodule ConvergerWeb.GRPCClient do
  @moduledoc """
  A minimal Converger Protocol v1 gRPC client for tests: the `grpc` library's
  client (Mint adapter) on `converger.v1.ChannelStream/Connect`, against the
  gRPC endpoint served by `start_server/0`.

  Frames are written as JSON maps and mapped to protobuf with
  `ConvergerWeb.GRPC.Frames` (as an Elixir client would); every server frame
  received is mapped back to JSON and validated against the protocol's JSON
  Schema (`server-frame.schema.json`), so the gRPC transport is held to the
  same frame contract as the WebSocket.

  `recv/2` returns a frame map, `{:close, code}` for the gRPC-only `Close`
  frame, `{:status, status}` when the RPC ends (status atom, `:ok` included),
  or `:timeout`.
  """

  import ExUnit.Assertions

  alias Converger.ProtocolSchemas
  alias Converger.V1.ChannelStream.Stub
  alias ConvergerWeb.GRPC.Frames

  defstruct [:channel, :stream, :ref, :reader]

  @doc """
  Starts the gRPC endpoint on a random loopback port for the calling test
  module (call from `setup_all`); returns the port. The `grpc` application
  starts the client supervisor itself.
  """
  def start_server do
    opts =
      ConvergerWeb.GRPC.server_options()
      |> Keyword.update!(:adapter_opts, &Keyword.put(&1, :ip, {127, 0, 0, 1}))

    {:ok, _pid, port} = GRPC.Server.start_endpoint(ConvergerWeb.GRPC.Endpoint, 0, opts)
    ExUnit.Callbacks.on_exit(fn -> GRPC.Server.stop_endpoint(ConvergerWeb.GRPC.Endpoint) end)
    port
  end

  @doc "Opens a `Connect` stream. Options: `:token` (sent as `authorization` metadata)."
  def connect(port, opts \\ []) do
    {:ok, channel} =
      GRPC.Stub.connect("127.0.0.1:#{port}", adapter: GRPC.Client.Adapters.Mint)

    metadata =
      case Keyword.get(opts, :token) do
        nil -> %{}
        token -> %{"authorization" => "Bearer #{token}"}
      end

    stream = Stub.connect(channel, metadata: metadata)
    %__MODULE__{channel: channel, stream: stream, ref: make_ref()}
  end

  @doc "Sends a frame: a JSON map (mapped with `ConvergerWeb.GRPC.Frames`) or a `ClientFrame`."
  def push(%__MODULE__{} = client, %Converger.V1.ClientFrame{} = frame) do
    client =
      try do
        %{client | stream: GRPC.Stub.send_request(client.stream, frame)}
      catch
        # The server may end the stream while a large message is still being sent.
        :exit, _reason -> client
      end

    start_reader(client)
  end

  def push(%__MODULE__{} = client, frame) when is_map(frame),
    do: push(client, Frames.to_client_frame(frame))

  @doc "Half-closes the client side of the stream."
  def end_stream(%__MODULE__{} = client), do: GRPC.Stub.end_stream(client.stream)

  @doc "Cancels the stream (RST_STREAM) and closes the connection."
  def cancel(%__MODULE__{} = client) do
    GRPC.Stub.cancel(client.stream)
    GRPC.Stub.disconnect(client.channel)
  catch
    # Already gone (the stream ended, or the test process exited).
    :exit, _reason -> :ok
  end

  # The replies are read by a process of their own, which forwards them to
  # the test process, so `recv/2` can time out.
  defp start_reader(%__MODULE__{reader: nil} = client) do
    test = self()
    %{ref: ref, stream: stream} = client

    reader =
      spawn_link(fn ->
        case GRPC.Stub.recv(stream, timeout: :infinity) do
          {:ok, replies} ->
            Enum.each(replies, &send(test, {ref, &1}))
            # The RPC ended with OK (an error status is an {:error, _} item).
            send(test, {ref, :done})

          {:error, error} ->
            send(test, {ref, {:error, error}})
        end
      end)

    %{client | reader: reader}
  end

  defp start_reader(client), do: client

  @doc "The next server frame (see the module docs)."
  def recv(%__MODULE__{ref: ref} = client, timeout \\ 2_000) do
    receive do
      {^ref, {:ok, %Converger.V1.ServerFrame{} = frame}} -> decode(frame)
      {^ref, {:error, %GRPC.RPCError{status: status}}} -> {:status, status_name(status)}
      {^ref, {:trailers, _trailers}} -> recv(client, timeout)
      {^ref, :done} -> {:status, :ok}
    after
      timeout -> :timeout
    end
  end

  @doc "Receives until a frame of `type`, ignoring others."
  def recv_type(client, type, timeout \\ 2_000) do
    case recv(client, timeout) do
      %{"type" => ^type} = frame -> frame
      %{} -> recv_type(client, type, timeout)
      other -> flunk("expected a #{type} frame, got #{inspect(other)}")
    end
  end

  @doc "Asserts that no frame arrives within `timeout`."
  def refute_frame(client, timeout \\ 200) do
    case recv(client, timeout) do
      :timeout -> :ok
      other -> flunk("unexpected frame #{inspect(other)}")
    end
  end

  defp decode(%Converger.V1.ServerFrame{frame: {:close, close}}), do: {:close, close.code}

  defp decode(frame) do
    json = Frames.from_server_frame(frame)

    case ProtocolSchemas.validate(json, server_frame_root()) do
      :ok -> json
      {:error, message} -> flunk("invalid server frame #{inspect(json)}: #{message}")
    end
  end

  defp status_name(status) when is_atom(status), do: status

  defp status_name(status) when is_integer(status) do
    Enum.find(
      ~w(ok cancelled unknown invalid_argument deadline_exceeded not_found already_exists
         permission_denied resource_exhausted failed_precondition aborted out_of_range
         unimplemented internal unavailable data_loss unauthenticated)a,
      fn name -> apply(GRPC.Status, name, []) == status end
    )
  end

  defp server_frame_root do
    case :persistent_term.get({__MODULE__, :root}, nil) do
      nil ->
        root = ProtocolSchemas.build!("server-frame.schema.json")
        :persistent_term.put({__MODULE__, :root}, root)
        root

      root ->
        root
    end
  end
end
