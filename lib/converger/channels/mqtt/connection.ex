defmodule Converger.Channels.Mqtt.Connection do
  @moduledoc """
  A minimal MQTT 3.1.1 client connection (TCP or TLS) of the `mqtt` channel:
  connect, subscribe, publish with QoS 0 or 1, keepalive.

  The difference with the MQTT clients on Hex (see ADR-0055) is that an
  inbound QoS 1 message is **not** acknowledged on receipt: the connection
  sends it to its owner as `{:mqtt_publish, connection, packet}`, and
  `PUBACK` goes out only when the owner calls `ack/2`, after the message was
  accepted or dead-lettered. A message the owner never acknowledges (a crash,
  a restart) stays unacknowledged at the broker, which delivers it again on
  the next connection of the same persistent session.

  The connection is set up in `init/1`: `start_link/1` returns once the
  broker accepted `CONNECT` and every `SUBSCRIBE`, or `{:error, reason}`.
  It does not reconnect: it stops when the socket closes, the broker stops
  answering pings, or a packet is malformed, and the supervisor (the
  channel's consumer, or the next delivery for a publisher) starts a new
  one. It traps exits, so it disconnects cleanly (`DISCONNECT`) when its
  owner or supervisor stops it.

  ## Options

    * `:host`, `:port` - the broker
    * `:ssl` - `false` (default) or `:ssl` client options (TLS)
    * `:client_id`, `:username`, `:password`
    * `:clean_session` - default `true`; `false` keeps the session (its
      subscriptions and the QoS 1 messages queued while disconnected)
    * `:keepalive` - seconds, default 30. A `PINGREQ` is sent every half
      keepalive; no `PINGRESP` before the next one closes the connection.
    * `:subscriptions` - `[{filter, qos}]`, subscribed after `CONNACK`
    * `:owner` - the process inbound messages are sent to (default: the
      caller of `start_link/1`)
    * `:connect_timeout` - milliseconds for the socket, `CONNACK` and
      `SUBACK`, default 10 000
    * `:idle_ms` - stop after this long without a publish (publishers)
    * `:name` - a `GenServer` name
  """

  use GenServer, restart: :temporary

  require Logger

  alias Converger.Channels.Mqtt.Packet

  @connack_errors %{
    1 => :unacceptable_protocol_version,
    2 => :identifier_rejected,
    3 => :server_unavailable,
    4 => :bad_username_or_password,
    5 => :not_authorized
  }

  @doc "Start a connection, see the module doc for the options."
  def start_link(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Like `start_link/1`, without a link (health probes)."
  def start(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Publish `payload` to `topic`. With QoS 1 it waits for the broker's
  `PUBACK` (`:timeout`, default 10 s). Returns `:ok` or `{:error, reason}`:
  `:puback_timeout`, `:closed`, `{:exit, reason}`.
  """
  @spec publish(GenServer.server(), String.t(), binary(), 0 | 1, keyword()) ::
          :ok | {:error, term()}
  def publish(conn, topic, payload, qos, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    GenServer.call(
      conn,
      {:publish, topic, payload, qos, Keyword.get(opts, :retain, false), timeout},
      timeout + 5_000
    )
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Acknowledge (`PUBACK`) the inbound QoS 1 message `packet_id`."
  @spec ack(GenServer.server(), pos_integer()) :: :ok
  def ack(conn, packet_id), do: GenServer.cast(conn, {:ack, packet_id})

  @doc "Disconnect (`DISCONNECT`) and stop."
  def stop(conn), do: GenServer.stop(conn, :normal)

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    transport = if Keyword.get(opts, :ssl, false), do: :ssl, else: :gen_tcp
    timeout = Keyword.get(opts, :connect_timeout, 10_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    keepalive = Keyword.get(opts, :keepalive, 30)

    state = %{
      transport: transport,
      socket: nil,
      owner: Keyword.fetch!(opts, :owner),
      buffer: <<>>,
      keepalive_ms: keepalive * 1000,
      ping_pending: false,
      inflight: %{},
      next_id: 1,
      idle_ms: Keyword.get(opts, :idle_ms),
      last_used: System.monotonic_time(:millisecond),
      session_present: false
    }

    case open(transport, opts, timeout) do
      {:ok, socket} -> handshake(%{state | socket: socket}, opts, keepalive, deadline)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp handshake(state, opts, keepalive, deadline) do
    with :ok <- send_packet(state, Packet.connect(connect_options(opts, keepalive))),
         {:ok, state} <- await_connack(state, deadline),
         {:ok, state} <- subscribe(state, Keyword.get(opts, :subscriptions, []), deadline),
         :ok <- activate(state) do
      schedule_tick(state)
      {:ok, state}
    else
      {:error, reason, _state} ->
        state.transport.close(state.socket)
        {:stop, reason}

      {:error, reason} ->
        state.transport.close(state.socket)
        {:stop, reason}
    end
  end

  defp connect_options(opts, keepalive) do
    [
      client_id: Keyword.fetch!(opts, :client_id),
      clean_session: Keyword.get(opts, :clean_session, true),
      keepalive: keepalive,
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password)
    ]
  end

  defp open(transport, opts, timeout) do
    host = opts |> Keyword.fetch!(:host) |> String.to_charlist()
    base = [:binary, active: false, packet: :raw]

    options =
      case transport do
        :gen_tcp -> [{:nodelay, true} | base]
        :ssl -> base ++ Keyword.fetch!(opts, :ssl)
      end

    case transport.connect(host, Keyword.fetch!(opts, :port), options, timeout) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  defp await_connack(state, deadline) do
    case recv_packet(state, deadline) do
      {:ok, %{type: :connack, return_code: 0, session_present: present}, state} ->
        {:ok, %{state | session_present: present}}

      {:ok, %{type: :connack, return_code: code}, state} ->
        {:error, {:connection_refused, Map.get(@connack_errors, code, code)}, state}

      {:ok, packet, state} ->
        {:error, {:unexpected_packet, packet.type}, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  # SUBSCRIBE is sent even when the session is present (it replaces the
  # stored subscription). Messages the broker sends before the SUBACK (those
  # queued in a persistent session) are passed on to the owner.
  defp subscribe(state, [], _deadline), do: {:ok, state}

  defp subscribe(state, filters, deadline) do
    with :ok <- send_packet(state, Packet.subscribe(1, filters)) do
      await_suback(state, filters, deadline)
    end
  end

  defp await_suback(state, filters, deadline) do
    case recv_packet(state, deadline) do
      {:ok, %{type: :suback, packet_id: 1, return_codes: codes}, state} ->
        case Enum.find(Enum.zip(filters, codes), fn {_filter, code} -> code == 0x80 end) do
          nil -> {:ok, state}
          {{filter, _qos}, _code} -> {:error, {:subscribe_failed, filter}, state}
        end

      {:ok, %{type: :publish} = packet, state} ->
        deliver(state, packet)
        await_suback(state, filters, deadline)

      {:ok, packet, state} ->
        {:error, {:unexpected_packet, packet.type}, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp recv_packet(state, deadline) do
    case Packet.decode(state.buffer) do
      {:ok, packet, rest} ->
        {:ok, packet, %{state | buffer: rest}}

      {:error, reason} ->
        {:error, {:protocol_error, reason}, state}

      :more ->
        remaining = deadline - System.monotonic_time(:millisecond)

        with true <- remaining > 0 || {:error, :timeout},
             {:ok, data} <- state.transport.recv(state.socket, 0, remaining) do
          recv_packet(%{state | buffer: state.buffer <> data}, deadline)
        else
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  @impl true
  def handle_call({:publish, topic, payload, qos, retain, timeout}, from, state) do
    state = %{state | last_used: System.monotonic_time(:millisecond)}

    case qos do
      0 ->
        {:reply, send_packet(state, Packet.publish(topic, payload, 0, nil, retain: retain)),
         state}

      1 ->
        {id, state} = next_id(state)

        case send_packet(state, Packet.publish(topic, payload, 1, id, retain: retain)) do
          :ok ->
            timer = Process.send_after(self(), {:puback_timeout, id}, timeout)
            {:noreply, put_in(state.inflight[id], {from, timer})}

          {:error, reason} ->
            {:stop, {:shutdown, {:send_failed, reason}}, {:error, :closed}, state}
        end
    end
  end

  @impl true
  def handle_cast({:ack, packet_id}, state) do
    case send_packet(state, Packet.puback(packet_id)) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:shutdown, {:send_failed, reason}}, state}
    end
  end

  @impl true
  def handle_info({tag, socket, data}, %{socket: socket} = state) when tag in [:tcp, :ssl] do
    handle_data(%{state | buffer: state.buffer <> data})
  end

  def handle_info({tag, socket}, %{socket: socket} = state)
      when tag in [:tcp_closed, :ssl_closed] do
    {:stop, {:shutdown, :closed}, %{state | socket: nil}}
  end

  def handle_info({tag, socket, reason}, %{socket: socket} = state)
      when tag in [:tcp_error, :ssl_error] do
    {:stop, {:shutdown, {:socket_error, reason}}, state}
  end

  def handle_info(:tick, state) do
    cond do
      state.ping_pending ->
        Logger.warning("MQTT broker did not answer the keepalive ping, closing the connection")
        {:stop, {:shutdown, :keepalive_timeout}, state}

      idle?(state) ->
        {:stop, :normal, state}

      true ->
        case send_packet(state, Packet.pingreq()) do
          :ok ->
            schedule_tick(state)
            {:noreply, %{state | ping_pending: true}}

          {:error, reason} ->
            {:stop, {:shutdown, {:send_failed, reason}}, state}
        end
    end
  end

  def handle_info({:puback_timeout, id}, state) do
    case Map.pop(state.inflight, id) do
      {{from, _timer}, inflight} ->
        GenServer.reply(from, {:error, :puback_timeout})
        {:noreply, %{state | inflight: inflight}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # The owner or the supervisor stopped: disconnect (terminate/2).
  def handle_info({:EXIT, pid, reason}, state) when is_pid(pid), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_data(state) do
    case Packet.decode(state.buffer) do
      {:ok, packet, rest} ->
        case handle_packet(packet, %{state | buffer: rest}) do
          {:ok, state} -> handle_data(state)
          {:stop, reason, state} -> {:stop, reason, state}
        end

      :more ->
        case activate(state) do
          :ok -> {:noreply, state}
          {:error, reason} -> {:stop, {:shutdown, {:socket_error, reason}}, state}
        end

      {:error, reason} ->
        Logger.warning("MQTT protocol error, closing the connection", reason: inspect(reason))
        {:stop, {:shutdown, {:protocol_error, reason}}, state}
    end
  end

  defp handle_packet(%{type: :publish} = packet, state) do
    deliver(state, packet)
    {:ok, state}
  end

  defp handle_packet(%{type: :puback, packet_id: id}, state) do
    case Map.pop(state.inflight, id) do
      {{from, timer}, inflight} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, :ok)
        {:ok, %{state | inflight: inflight}}

      {nil, _} ->
        {:ok, state}
    end
  end

  defp handle_packet(%{type: :pingresp}, state), do: {:ok, %{state | ping_pending: false}}

  defp handle_packet(packet, state),
    do: {:stop, {:shutdown, {:protocol_error, {:unexpected_packet, packet.type}}}, state}

  defp deliver(state, packet), do: send(state.owner, {:mqtt_publish, self(), packet})

  @impl true
  def terminate(_reason, state) do
    for {_id, {from, timer}} <- state.inflight do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :closed})
    end

    if state.socket do
      _ = send_packet(state, Packet.disconnect())
      state.transport.close(state.socket)
    end

    :ok
  end

  ## Helpers

  defp send_packet(state, iodata), do: state.transport.send(state.socket, iodata)

  defp activate(%{transport: :gen_tcp, socket: socket}), do: :inet.setopts(socket, active: :once)
  defp activate(%{transport: :ssl, socket: socket}), do: :ssl.setopts(socket, active: :once)

  defp schedule_tick(state),
    do: Process.send_after(self(), :tick, max(div(state.keepalive_ms, 2), 500))

  defp idle?(%{idle_ms: idle_ms} = state) when is_integer(idle_ms),
    do:
      map_size(state.inflight) == 0 and
        System.monotonic_time(:millisecond) - state.last_used >= idle_ms

  defp idle?(_state), do: false

  # Packet ids of our QoS 1 publishes: 1..65535, skipping ids in flight.
  defp next_id(state) do
    id = state.next_id
    next = if id >= 65_535, do: 1, else: id + 1

    if Map.has_key?(state.inflight, id),
      do: next_id(%{state | next_id: next}),
      else: {id, %{state | next_id: next}}
  end
end
