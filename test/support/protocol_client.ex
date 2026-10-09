defmodule ConvergerWeb.ProtocolClient do
  @moduledoc """
  A minimal Converger Protocol v1 client for tests: a real WebSocket
  (`Mint.WebSocket`) or Server-Sent Events (`Mint.HTTP`) connection to an
  endpoint served by `start_server/0`.

  The calling process owns the connection; `recv/2` returns the next frame
  (decoded) and every server frame is validated against the protocol's
  JSON Schema (`server-frame.schema.json`).
  """

  import ExUnit.Assertions

  alias Converger.ProtocolSchemas

  defstruct [:conn, :ref, :websocket, :encoding, :status, buffer: [], sse_buffer: ""]

  @doc "Serve `ConvergerWeb.Endpoint` over HTTP on a random port; returns the port."
  def start_server do
    pid =
      ExUnit.Callbacks.start_supervised!({
        Bandit,
        # Open SSE streams and sockets must not hold up the test.
        plug: ConvergerWeb.Endpoint,
        ip: :loopback,
        port: 0,
        startup_log: false,
        thousand_island_options: [shutdown_timeout: 100]
      })

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  ## WebSocket

  @doc """
  Open a WebSocket. Options: `:path` (default `/socket/converger/v1`),
  `:headers`, `:subprotocols` (offered in order), `:encoding` (`:json` or
  `:msgpack`, how frames are sent).

  Returns `{:ok, client}` or `{:error, status}` when the upgrade is refused.
  """
  def connect(port, opts \\ []) do
    path = Keyword.get(opts, :path, "/socket/converger/v1")
    headers = Keyword.get(opts, :headers, [])

    headers =
      case Keyword.get(opts, :subprotocols, []) do
        [] -> headers
        protocols -> [{"sec-websocket-protocol", Enum.join(protocols, ", ")} | headers]
      end

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, headers)
    {conn, status, resp_headers} = await_response(conn, ref, nil, [])

    case Mint.WebSocket.new(conn, ref, status, resp_headers) do
      {:ok, conn, websocket} ->
        {:ok,
         %__MODULE__{
           conn: conn,
           ref: ref,
           websocket: websocket,
           encoding: Keyword.get(opts, :encoding, :json),
           status: {status, resp_headers}
         }}

      {:error, _conn, _reason} ->
        {:error, status}
    end
  end

  defp await_response(conn, ref, status, headers) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      message when elem(message, 0) in [:tcp, :tcp_closed] and elem(message, 1) == socket ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)

        {status, headers, done?} =
          Enum.reduce(responses, {status, headers, false}, fn
            {:status, ^ref, status}, {_, headers, done?} -> {status, headers, done?}
            {:headers, ^ref, new}, {status, headers, done?} -> {status, headers ++ new, done?}
            {:done, ^ref}, {status, headers, _} -> {status, headers, true}
            _other, acc -> acc
          end)

        if done?, do: {conn, status, headers}, else: await_response(conn, ref, status, headers)
    after
      2_000 -> flunk("no upgrade response")
    end
  end

  @doc "The negotiated subprotocol (response header), or nil."
  def subprotocol(%__MODULE__{status: {_status, headers}}) do
    Enum.find_value(headers, fn {name, value} ->
      if name == "sec-websocket-protocol", do: value
    end)
  end

  @doc "Send a frame (a map), or a raw `{:text | :binary, data}` message."
  def push(%__MODULE__{} = client, {opcode, _data} = message) when opcode in [:text, :binary] do
    {:ok, websocket, data} = Mint.WebSocket.encode(client.websocket, message)
    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
    %{client | conn: conn, websocket: websocket}
  end

  def push(%__MODULE__{encoding: :json} = client, frame),
    do: push(client, {:text, Jason.encode!(frame)})

  def push(%__MODULE__{encoding: :msgpack} = client, frame),
    do: push(client, {:binary, Msgpax.pack!(frame, iodata: false)})

  @doc """
  The next server frame: `{frame, client}`, `{{:close, code}, client}`, or
  `{:timeout, client}`.
  """
  def recv(client, timeout \\ 1_000)

  def recv(%__MODULE__{buffer: [next | rest]} = client, _timeout),
    do: {next, %{client | buffer: rest}}

  def recv(%__MODULE__{} = client, timeout) do
    socket = Mint.HTTP.get_socket(client.conn)

    receive do
      message when elem(message, 0) in [:tcp, :tcp_closed] and elem(message, 1) == socket ->
        case Mint.WebSocket.stream(client.conn, message) do
          {:ok, conn, responses} ->
            client = Enum.reduce(responses, %{client | conn: conn}, &decode_response/2)
            recv(client, timeout)

          {:error, conn, _error, _responses} ->
            recv(%{client | conn: conn, buffer: [{:close, :closed}]}, timeout)
        end
    after
      timeout -> {:timeout, client}
    end
  end

  defp decode_response({:data, _ref, data}, client) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(client.websocket, data)
    %{client | websocket: websocket, buffer: client.buffer ++ Enum.flat_map(frames, &frame/1)}
  end

  defp decode_response(_other, client), do: client

  defp frame({:text, json}), do: [validated(Jason.decode!(json))]
  defp frame({:binary, data}), do: [validated(Msgpax.unpack!(data))]
  defp frame({:close, code, _reason}), do: [{:close, code}]
  defp frame(_control), do: []

  @doc "Receive frames until one matches `type`, returning it (others are dropped)."
  def recv_type(client, type, timeout \\ 1_000) do
    case recv(client, timeout) do
      {%{"type" => ^type} = frame, client} -> {frame, client}
      {%{}, client} -> recv_type(client, type, timeout)
      {other, _client} -> flunk("expected a #{type} frame, got #{inspect(other)}")
    end
  end

  @doc "Assert that no frame arrives within `timeout`."
  def refute_frame(client, timeout \\ 200) do
    case recv(client, timeout) do
      {:timeout, client} -> client
      {frame, _client} -> flunk("unexpected frame #{inspect(frame)}")
    end
  end

  def close(%__MODULE__{conn: conn}), do: Mint.HTTP.close(conn)

  ## Server-Sent Events

  @doc "Open an SSE stream. Returns `{status, client}`."
  def sse_connect(port, path, headers \\ []) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    headers = [{"accept", "text/event-stream"} | headers]
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", path, headers, nil)
    client = %__MODULE__{conn: conn, ref: ref}
    sse_status(client)
  end

  defp sse_status(client) do
    socket = Mint.HTTP.get_socket(client.conn)

    receive do
      message when elem(message, 0) in [:tcp, :tcp_closed] and elem(message, 1) == socket ->
        {:ok, conn, responses} = Mint.HTTP.stream(client.conn, message)
        client = Enum.reduce(responses, %{client | conn: conn}, &sse_response/2)

        case client.status do
          nil -> sse_status(client)
          status -> {status, client}
        end
    after
      2_000 -> flunk("no SSE response")
    end
  end

  defp sse_response({:status, _ref, status}, client), do: %{client | status: status}
  defp sse_response({:data, _ref, data}, client), do: parse_sse(client, data)
  defp sse_response({:done, _ref}, client), do: %{client | buffer: client.buffer ++ [:done]}
  defp sse_response(_other, client), do: client

  defp parse_sse(client, data) do
    parts = String.split(client.sse_buffer <> data, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)

    events =
      complete
      |> Enum.map(&parse_event/1)
      |> Enum.reject(&is_nil/1)

    %{client | sse_buffer: rest, buffer: client.buffer ++ events}
  end

  defp parse_event(block) do
    fields =
      block
      |> String.split("\n")
      |> Enum.map(&String.split(&1, ": ", parts: 2))
      |> Enum.flat_map(fn
        [key, value] -> [{key, value}]
        _ -> []
      end)
      |> Map.new()

    case fields do
      %{"data" => data} ->
        frame = validated(Jason.decode!(data))
        assert fields["event"] == frame["type"]
        %{id: fields["id"], frame: frame}

      _ ->
        nil
    end
  end

  @doc "The next SSE event `%{id, frame}`, `:done`, or `:timeout`."
  def sse_recv(client, timeout \\ 1_000)

  def sse_recv(%__MODULE__{buffer: [next | rest]} = client, _timeout),
    do: {next, %{client | buffer: rest}}

  def sse_recv(%__MODULE__{} = client, timeout) do
    socket = Mint.HTTP.get_socket(client.conn)

    receive do
      message when elem(message, 0) in [:tcp, :tcp_closed] and elem(message, 1) == socket ->
        case Mint.HTTP.stream(client.conn, message) do
          {:ok, conn, responses} ->
            sse_recv(Enum.reduce(responses, %{client | conn: conn}, &sse_response/2), timeout)

          {:error, conn, _error, _responses} ->
            sse_recv(%{client | conn: conn, buffer: [:done]}, timeout)
        end
    after
      timeout -> {:timeout, client}
    end
  end

  ## Schema validation

  defp validated(frame) do
    root = server_frame_root()

    case ProtocolSchemas.validate(frame, root) do
      :ok -> frame
      {:error, message} -> flunk("invalid server frame #{inspect(frame)}: #{message}")
    end
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
