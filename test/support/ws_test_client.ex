defmodule ConvergerWeb.WsTestClient do
  @moduledoc """
  A minimal WebSocket client over `:gen_tcp` for tests that need the real
  transport (frame size limits, close codes), which `Phoenix.ChannelTest`
  bypasses. Speaks the Phoenix V2 JSON serializer:
  `[join_ref, ref, topic, event, payload]`.
  """

  import Bitwise

  @doc "Starts a Bandit listener for the endpoint on a random port; returns the port."
  def start_server do
    {:ok, pid} =
      Bandit.start_link(
        plug: ConvergerWeb.Endpoint,
        ip: :loopback,
        port: 0,
        startup_log: false,
        websocket_options: ConvergerWeb.Endpoint.config(:http)[:websocket_options]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, port}
  end

  @doc """
  Opens a WebSocket to `path` (with query string). Returns `{:ok, socket}` or
  `{:error, {:http, status, headers}}` when the upgrade is refused.
  """
  def connect(port, path) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :http_bin])

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(sock, [
        "GET #{path} HTTP/1.1\r\n",
        "Host: 127.0.0.1:#{port}\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: #{key}\r\n",
        "Sec-WebSocket-Version: 13\r\n\r\n"
      ])

    {:ok, {:http_response, _, status, _}} = :gen_tcp.recv(sock, 0, 5_000)
    headers = read_headers(sock, [])
    :ok = :inet.setopts(sock, packet: :raw)

    if status == 101 do
      {:ok, sock}
    else
      :gen_tcp.close(sock)
      {:error, {:http, status, headers}}
    end
  end

  defp read_headers(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(sock, [{String.downcase(to_string(name)), value} | acc])

      {:ok, :http_eoh} ->
        acc
    end
  end

  @doc "Sends a Phoenix message."
  def push(sock, join_ref, ref, topic, event, payload) do
    send_text(sock, Jason.encode!([join_ref, ref, topic, event, payload]))
  end

  @doc "Sends a masked text frame with the given payload."
  def send_text(sock, data) do
    mask = :crypto.strong_rand_bytes(4)
    size = byte_size(data)

    length =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    :gen_tcp.send(sock, [<<1::1, 0::3, 1::4>>, length, mask, mask(data, mask)])
  end

  @doc """
  Receives the next frame: `{:message, [join_ref, ref, topic, event, payload]}`,
  `{:close, code, reason}` or `{:error, reason}`.
  """
  def recv(sock, timeout \\ 5_000) do
    with {:ok, <<_fin::1, _rsv::3, opcode::4, _masked::1, len::7>>} <-
           :gen_tcp.recv(sock, 2, timeout),
         {:ok, len} <- payload_length(sock, len, timeout),
         {:ok, payload} <- recv_payload(sock, len, timeout) do
      case opcode do
        1 -> {:message, Jason.decode!(payload)}
        8 -> close_frame(payload)
        _ -> recv(sock, timeout)
      end
    end
  end

  defp payload_length(sock, 126, timeout) do
    with {:ok, <<len::16>>} <- :gen_tcp.recv(sock, 2, timeout), do: {:ok, len}
  end

  defp payload_length(sock, 127, timeout) do
    with {:ok, <<len::64>>} <- :gen_tcp.recv(sock, 8, timeout), do: {:ok, len}
  end

  defp payload_length(_sock, len, _timeout), do: {:ok, len}

  defp recv_payload(_sock, 0, _timeout), do: {:ok, ""}
  defp recv_payload(sock, len, timeout), do: :gen_tcp.recv(sock, len, timeout)

  defp close_frame(<<code::16, reason::binary>>), do: {:close, code, reason}
  defp close_frame(<<>>), do: {:close, nil, ""}

  @doc "Receives frames until one matches `fun`, or fails after `timeout`."
  def recv_until(sock, fun, timeout \\ 5_000) do
    frame = recv(sock, timeout)

    if fun.(frame) or match?({:close, _, _}, frame) or match?({:error, _}, frame),
      do: frame,
      else: recv_until(sock, fun, timeout)
  end

  defp mask(data, <<m::32>>) do
    words = div(byte_size(data), 4) * 4
    head = binary_part(data, 0, words)
    tail = binary_part(data, words, byte_size(data) - words)

    masked_head = for <<w::32 <- head>>, into: <<>>, do: <<bxor(w, m)::32>>

    masked_tail =
      tail
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {b, i} -> bxor(b, m >>> (8 * (3 - i)) &&& 0xFF) end)
      |> :binary.list_to_bin()

    masked_head <> masked_tail
  end
end
