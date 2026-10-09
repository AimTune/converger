defmodule Converger.TestCluster.WsClient do
  @moduledoc """
  Minimal WebSocket client (RFC 6455) over `:gen_tcp` that speaks the Phoenix
  V2 JSON socket protocol. Used by the multi-node suite (`test/cluster`) to
  talk to a real node over the network; the app has no WebSocket client
  dependency.
  """

  defstruct [:socket, buffer: "", ref: 0]

  @type t :: %__MODULE__{}

  @doc "Connects and performs the upgrade handshake for `path` (with query string)."
  @spec connect(:inet.port_number(), String.t()) :: {:ok, t()} | {:error, term()}
  def connect(port, path) do
    with {:ok, socket} <-
           :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000) do
      key = Base.encode64(:crypto.strong_rand_bytes(16))

      request =
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nUpgrade: websocket\r\n" <>
          "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"

      :ok = :gen_tcp.send(socket, request)

      case read_handshake(socket, "") do
        {:ok, "HTTP/1.1 101" <> _, rest} -> {:ok, %__MODULE__{socket: socket, buffer: rest}}
        {:ok, status_line, _rest} -> {:error, {:upgrade_failed, status_line}}
        error -> error
      end
    end
  end

  @doc "Joins `topic` and waits for the `phx_reply`. Returns the reply payload."
  @spec join(t(), String.t(), map()) :: {:ok | :error, map(), t()}
  def join(client, topic, payload \\ %{}) do
    ref = to_string(client.ref + 1)
    client = %{client | ref: client.ref + 1}
    :ok = push_frame(client, [ref, ref, topic, "phx_join", payload])

    {:ok, [_join_ref, ^ref, ^topic, "phx_reply", %{"status" => status, "response" => response}],
     client} =
      await(client, &match?([_, ^ref, ^topic, "phx_reply", _], &1))

    {if(status == "ok", do: :ok, else: :error), response, client}
  end

  @doc """
  Reads messages until one satisfies `fun`; returns it. Messages that do not
  match are dropped.
  """
  @spec await(t(), (list() -> boolean()), timeout()) :: {:ok, list(), t()} | {:error, term()}
  def await(client, fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(client, fun, deadline)
  end

  defp do_await(client, fun, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case next_message(client, remaining) do
      {:ok, message, client} ->
        if fun.(message), do: {:ok, message, client}, else: do_await(client, fun, deadline)

      error ->
        error
    end
  end

  @doc "Closes the TCP connection."
  def close(%__MODULE__{socket: socket}), do: :gen_tcp.close(socket)

  defp next_message(client, timeout) do
    case parse_frame(client.buffer) do
      {:ok, 0x1, payload, rest} ->
        {:ok, Jason.decode!(payload), %{client | buffer: rest}}

      {:ok, 0x9, payload, rest} ->
        :ok = :gen_tcp.send(client.socket, frame(0xA, payload))
        next_message(%{client | buffer: rest}, timeout)

      {:ok, 0x8, _payload, _rest} ->
        {:error, :closed}

      {:ok, _opcode, _payload, rest} ->
        next_message(%{client | buffer: rest}, timeout)

      :more ->
        case :gen_tcp.recv(client.socket, 0, timeout) do
          {:ok, data} -> next_message(%{client | buffer: client.buffer <> data}, timeout)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Server frames are unmasked; fragmented messages are not used by Phoenix.
  defp parse_frame(<<_fin::1, _rsv::3, opcode::4, 0::1, 127::7, len::64, rest::binary>>),
    do: take(opcode, len, rest)

  defp parse_frame(<<_fin::1, _rsv::3, opcode::4, 0::1, 126::7, len::16, rest::binary>>),
    do: take(opcode, len, rest)

  defp parse_frame(<<_fin::1, _rsv::3, opcode::4, 0::1, len::7, rest::binary>>) when len < 126,
    do: take(opcode, len, rest)

  defp parse_frame(_buffer), do: :more

  defp take(opcode, len, rest) do
    case rest do
      <<payload::binary-size(len), rest::binary>> -> {:ok, opcode, payload, rest}
      _ -> :more
    end
  end

  defp push_frame(client, message),
    do: :gen_tcp.send(client.socket, frame(0x1, Jason.encode!(message)))

  # Client frames must be masked.
  defp frame(opcode, payload) do
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)

    length_bits =
      cond do
        len < 126 -> <<1::1, len::7>>
        len < 65_536 -> <<1::1, 126::7, len::16>>
        true -> <<1::1, 127::7, len::64>>
      end

    <<1::1, 0::3, opcode::4, length_bits::bitstring, mask::binary, mask(payload, mask)::binary>>
  end

  defp mask(payload, <<a, b, c, d>>) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, elem({a, b, c, d}, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  defp read_handshake(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        [status_line | _] = String.split(head, "\r\n")
        {:ok, status_line, rest}

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_handshake(socket, acc <> data)
          error -> error
        end
    end
  end
end
