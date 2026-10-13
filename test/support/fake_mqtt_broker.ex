defmodule Converger.FakeMqttBroker do
  @moduledoc """
  A scriptable MQTT 3.1.1 broker for unit tests of
  `Converger.Channels.Mqtt.Connection` and the `mqtt` adapter, on a random
  loopback port. Every packet a client sends is reported to the test
  process as `{:mqtt_client, session, packet}`, where `packet` is
  `{:connect, %{client_id, clean_session, username, password, keepalive}}`,
  `{:subscribe, packet_id, [{filter, qos}]}`, `{:publish, %{topic, payload,
  qos, packet_id}}`, `{:puback, packet_id}`, `:pingreq` or `:disconnect`;
  `session` is the pid that owns the client socket.

  It answers by itself, according to options (`start_link/2`, `set/3`):
  `CONNECT` with `CONNACK` (`:connack_code`, default 0; `:session_present`,
  default false), `SUBSCRIBE` with `SUBACK` (`:suback`, a return code,
  default the requested QoS; `:after_connack`, iodata sent right after the
  `CONNACK`), `PINGREQ` with `PINGRESP` (unless `:pingresp`
  is false) and QoS 1 `PUBLISH` with `PUBACK` (unless `:puback` is false).
  `push/2` sends a packet (iodata) to a client, `close/1` closes its socket.
  """

  use GenServer

  import Bitwise

  def start_link(test, opts \\ []), do: GenServer.start_link(__MODULE__, {test, opts})

  def port(broker), do: GenServer.call(broker, :port)

  def set(broker, key, value), do: GenServer.call(broker, {:set, key, value})

  def get(broker, key, default), do: GenServer.call(broker, {:get, key, default})

  def push(session, iodata), do: send(session, {:push, iodata})

  def close(session), do: send(session, :close)

  @impl true
  def init({test, opts}) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    broker = self()
    spawn_link(fn -> accept(listen, broker, test) end)
    {:ok, %{listen: listen, port: port, opts: Map.new(opts)}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:set, key, value}, _from, state),
    do: {:reply, :ok, put_in(state.opts[key], value)}

  def handle_call({:get, key, default}, _from, state),
    do: {:reply, Map.get(state.opts, key, default), state}

  defp accept(listen, broker, test) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> session(broker, test) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:socket, socket})
        accept(listen, broker, test)

      {:error, _} ->
        :ok
    end
  end

  defp session(broker, test) do
    receive do
      {:socket, socket} ->
        :ok = :inet.setopts(socket, active: true)
        loop(%{socket: socket, broker: broker, test: test, buffer: <<>>})
    end
  end

  defp loop(state) do
    receive do
      {:tcp, _socket, data} ->
        state |> Map.update!(:buffer, &(&1 <> data)) |> parse() |> loop()

      {:tcp_closed, _socket} ->
        send(state.test, {:mqtt_client, self(), :closed})

      {:push, iodata} ->
        :gen_tcp.send(state.socket, iodata)
        loop(state)

      :close ->
        :gen_tcp.close(state.socket)
        send(state.test, {:mqtt_client, self(), :closed})
    end
  end

  defp parse(%{buffer: <<header, rest::binary>>} = state) do
    case remaining(rest, 0, 1) do
      {:ok, len, body_rest} when byte_size(body_rest) >= len ->
        <<body::binary-size(len), rest::binary>> = body_rest
        packet = decode(header >>> 4, header &&& 0x0F, body)
        send(state.test, {:mqtt_client, self(), packet})
        answer(packet, state)
        parse(%{state | buffer: rest})

      _ ->
        state
    end
  end

  defp parse(state), do: state

  defp remaining(<<1::1, v::7, rest::binary>>, acc, m), do: remaining(rest, acc + v * m, m * 128)
  defp remaining(<<0::1, v::7, rest::binary>>, acc, m), do: {:ok, acc + v * m, rest}
  defp remaining(<<>>, _acc, _m), do: :more

  defp decode(1, 0, <<4::16, "MQTT", 4, flags, keepalive::16, payload::binary>>) do
    [client_id | rest] = strings(payload)
    {username, rest} = if (flags &&& 0x80) != 0, do: {hd(rest), tl(rest)}, else: {nil, rest}
    password = if (flags &&& 0x40) != 0, do: hd(rest)

    {:connect,
     %{
       client_id: client_id,
       clean_session: (flags &&& 0x02) != 0,
       username: username,
       password: password,
       keepalive: keepalive
     }}
  end

  defp decode(3, flags, <<len::16, topic::binary-size(len), rest::binary>>) do
    qos = flags >>> 1 &&& 0b11

    {id, payload} =
      case {qos, rest} do
        {0, rest} -> {nil, rest}
        {_qos, <<id::16, payload::binary>>} -> {id, payload}
      end

    {:publish, %{topic: topic, payload: payload, qos: qos, packet_id: id}}
  end

  defp decode(4, 0, <<id::16>>), do: {:puback, id}

  defp decode(8, 2, <<id::16, rest::binary>>), do: {:subscribe, id, filters(rest)}
  defp decode(12, 0, <<>>), do: :pingreq
  defp decode(14, 0, <<>>), do: :disconnect
  defp decode(type, flags, body), do: {:unknown, type, flags, body}

  defp strings(<<len::16, s::binary-size(len), rest::binary>>), do: [s | strings(rest)]
  defp strings(<<>>), do: []

  defp filters(<<len::16, f::binary-size(len), qos, rest::binary>>),
    do: [{f, qos} | filters(rest)]

  defp filters(<<>>), do: []

  defp answer({:connect, _}, state) do
    code = get(state.broker, :connack_code, 0)
    present = if get(state.broker, :session_present, false), do: 1, else: 0
    :gen_tcp.send(state.socket, <<0x20, 2, present, code>>)

    # Messages of a persistent session, sent before the SUBACK.
    if queued = get(state.broker, :after_connack, nil), do: :gen_tcp.send(state.socket, queued)
  end

  defp answer({:subscribe, id, filters}, state) do
    codes =
      for {_filter, qos} <- filters, do: get(state.broker, :suback, qos)

    :gen_tcp.send(state.socket, [<<0x90, 2 + length(codes), id::16>>, codes])
  end

  defp answer(:pingreq, state) do
    if get(state.broker, :pingresp, true), do: :gen_tcp.send(state.socket, <<0xD0, 0>>)
  end

  defp answer({:publish, %{qos: 1, packet_id: id}}, state) do
    if get(state.broker, :puback, true), do: :gen_tcp.send(state.socket, <<0x40, 2, id::16>>)
  end

  defp answer(_packet, _state), do: :ok
end
