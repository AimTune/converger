defmodule ConvergerWeb.SocketGuard do
  @moduledoc """
  Per-socket limits and backpressure for the client WebSockets
  (`ConvergerWeb.UserSocket`, `ConvergerWeb.ConvergerSocket`).

  `use ConvergerWeb.SocketGuard` after `use Phoenix.Socket` wraps the socket's
  transport callbacks, which run in the socket (transport) process:

    * **Draining**: while `ConvergerWeb.Drain.draining?/0`, new connections are
      refused with HTTP 503 and `Retry-After`. Sockets drained on shutdown are
      closed with 1012 and a close reason `{"reason":"unavailable","retryAfterMs":N}`.
    * **Message rate**: at most `:max_messages` inbound frames per
      `:rate_window_ms` per socket. Above it a frame is not processed and is
      answered with an error reply `{"reason":"rate_limited","retryAfterMs":N}`.
    * **Frame size**: frames above `:max_frame_bytes` are answered with
      `{"reason":"payload_too_large"}` and not processed. Frames above the hard
      cap (`:websocket_max_frame_size`, enforced by Bandit) close the socket
      with 1009.
    * **Joins**: at most `:max_joins` joined channels per socket; further
      joins are refused with `{"reason":"too_many_joins"}`.
    * **Slow consumers**: when the socket process mailbox (frames waiting to
      be written to the client) grows past `:slow_consumer_queue_len`, the
      socket is closed with 4503 and `{"reason":"slow_consumer","retryAfterMs":N}`.
      Channels send ephemeral frames (typing, presence) with
      `push_ephemeral/3`, which drops them above `:ephemeral_drop_queue_len`.

  Limits come from `config :converger, :websocket`. Every rejection emits
  `[:converger, :socket, :limit]` with `%{count: 1}` and
  `%{reason: reason, socket: module}`.
  """

  require Logger

  alias Phoenix.Socket.Reply

  @rate_key {__MODULE__, :rate}

  @close_frame_too_large 1009
  @close_policy 1008
  @close_restart 1012
  @close_slow_consumer 4503

  defmacro __using__(_opts) do
    quote do
      defoverridable connect: 1, handle_in: 2, handle_info: 2, terminate: 2

      @doc false
      def connect(map) do
        if ConvergerWeb.Drain.draining?() do
          ConvergerWeb.SocketGuard.emit(:draining, __MODULE__)
          {:error, :draining}
        else
          super(map)
        end
      end

      @doc false
      def handle_in(message, state) do
        case ConvergerWeb.SocketGuard.check_in(message, state, __MODULE__) do
          :cont -> super(message, state)
          result -> result
        end
      end

      @doc false
      def handle_info(message, state) do
        case ConvergerWeb.SocketGuard.check_info(message, state, __MODULE__) do
          :cont -> super(message, state)
          result -> result
        end
      end

      @doc false
      def terminate(reason, state) do
        ConvergerWeb.SocketGuard.terminated(reason, __MODULE__)
        super(reason, state)
      end
    end
  end

  @doc """
  Pushes an ephemeral event (typing, presence) from a channel unless the
  client is not keeping up, in which case the event is dropped. Returns
  `:ok` or `:dropped`.
  """
  @spec push_ephemeral(Phoenix.Socket.t(), String.t(), map()) :: :ok | :dropped
  def push_ephemeral(%Phoenix.Socket{transport_pid: transport_pid} = socket, event, payload) do
    if queue_len(transport_pid) > config(:ephemeral_drop_queue_len) do
      emit(:ephemeral_dropped, socket.handler)
      :dropped
    else
      Phoenix.Channel.push(socket, event, payload)
    end
  end

  @doc false
  # Error handler for refused connections (`error_handler:` on the socket mounts).
  def handle_error(conn, :draining) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", to_string(div(retry_after_ms(), 1000) + 1))
    |> Plug.Conn.send_resp(503, "")
  end

  def handle_error(conn, _reason), do: Plug.Conn.send_resp(conn, 403, "")

  @doc false
  def check_in({payload, opts}, {phx_state, socket} = state, handler) do
    cond do
      (retry_after = rate_limited()) != nil ->
        reject(payload, opts, state, handler, :rate_limited, %{
          reason: "rate_limited",
          retryAfterMs: retry_after
        })

      byte_size(payload) > config(:max_frame_bytes) ->
        reject(payload, opts, state, handler, :payload_too_large, %{reason: "payload_too_large"})

      map_size(phx_state.channels) >= config(:max_joins) ->
        check_join(payload, opts, phx_state, socket, state, handler)

      true ->
        :cont
    end
  end

  @doc false
  def check_info({:socket_push, _opcode, _payload}, state, handler) do
    if queue_len(self()) > config(:slow_consumer_queue_len) do
      emit(:slow_consumer, handler)
      close(@close_slow_consumer, "slow_consumer", state)
    else
      :cont
    end
  end

  # Sent by a channel when Phoenix's drainer drains it on shutdown.
  def check_info(:socket_drain, state, _handler), do: close(@close_restart, "unavailable", state)

  def check_info(_message, _state, _handler), do: :cont

  @doc false
  def terminated({:error, :max_frame_size_exceeded}, handler) do
    emit(:frame_too_large, handler)
    Logger.info("WebSocket closed with 1009: frame above max_frame_size (#{inspect(handler)})")
  end

  def terminated(_reason, _handler), do: :ok

  @doc false
  def emit(reason, handler) do
    :telemetry.execute([:converger, :socket, :limit], %{count: 1}, %{
      reason: reason,
      socket: handler
    })
  end

  @doc """
  Counts one inbound frame against the per-socket rate (`:max_messages` per
  `:rate_window_ms`, a fixed window kept in the calling socket process).
  Returns nil when the frame is allowed, otherwise the ms until the window
  resets.
  """
  @spec rate_limited() :: nil | pos_integer()
  def rate_limited do
    now = System.monotonic_time(:millisecond)
    window = config(:rate_window_ms)

    {start, count} =
      case Process.get(@rate_key) do
        {start, count} when now - start < window -> {start, count + 1}
        _ -> {now, 1}
      end

    Process.put(@rate_key, {start, count})
    if count > config(:max_messages), do: max(start + window - now, 1)
  end

  # At the join cap: only a join of a new topic is refused.
  defp check_join(payload, opts, %{channels: channels}, socket, state, handler) do
    case decode(socket, payload, opts) do
      {:ok, %{event: "phx_join", topic: topic} = message}
      when not is_map_key(channels, topic) ->
        emit(:too_many_joins, handler)
        reply(socket, message, %{reason: "too_many_joins"}, state)

      _ ->
        :cont
    end
  end

  defp reject(payload, opts, {_phx_state, socket} = state, handler, reason, response) do
    emit(reason, handler)

    case decode(socket, payload, opts) do
      {:ok, message} ->
        reply(socket, message, response, state)

      :error when reason == :payload_too_large ->
        close(@close_frame_too_large, "payload_too_large", state)

      :error ->
        close(@close_policy, Atom.to_string(reason), state)
    end
  end

  defp reply(socket, message, response, state) do
    {:socket_push, opcode, data} =
      socket.serializer.encode!(%Reply{
        topic: message.topic,
        join_ref: message.join_ref,
        ref: message.ref,
        status: :error,
        payload: response
      })

    {:push, {opcode, data}, state}
  end

  defp decode(socket, payload, opts) do
    {:ok, socket.serializer.decode!(payload, opts)}
  rescue
    _ -> :error
  end

  defp close(code, reason, state), do: {:stop, :normal, close_detail(code, reason), state}

  @doc """
  The WebSocket close detail `{code, reason}` for a limit: the reason is JSON,
  `{"reason": reason}`, plus a jittered `retryAfterMs` for 1012 (draining)
  and 4503 (slow consumer). Shared with `ConvergerWeb.ProtocolSocket`.
  """
  @spec close_detail(integer(), String.t()) :: {integer(), String.t()}
  def close_detail(code, reason) do
    # Close reasons are at most 123 bytes; these stay well below.
    detail =
      if code in [@close_restart, @close_slow_consumer],
        do: %{reason: reason, retryAfterMs: retry_after_ms()},
        else: %{reason: reason}

    {code, Jason.encode!(detail)}
  end

  @doc "A jittered reconnect delay in ms (`:reconnect_base_ms` plus up to `:reconnect_jitter_ms`)."
  def retry_after_ms do
    config(:reconnect_base_ms) + :rand.uniform(config(:reconnect_jitter_ms) + 1) - 1
  end

  @doc "Messages waiting in `pid`'s mailbox (frames not yet written to a socket's client)."
  def queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len
      nil -> 0
    end
  end

  @doc "A limit from `config :converger, :websocket`."
  def config(key), do: Application.fetch_env!(:converger, :websocket)[key]
end
