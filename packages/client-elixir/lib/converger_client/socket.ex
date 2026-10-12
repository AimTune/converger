defmodule ConvergerClient.Socket do
  @moduledoc """
  Protocol v1 WebSocket client for the native endpoint
  (`/socket/converger/v1`), built on `Mint.WebSocket`.

      {:ok, sock} =
        ConvergerClient.Socket.start_link(
          client: client,                 # or url: "wss://host/socket/converger/v1"
          token: conversation_token,      # or a 0-arity function returning one
          conversation_id: conversation_id,
          watermark: stored_watermark
        )

      {:ok, %ConvergerClient.Ack{seq: seq}} = ConvergerClient.Socket.send_text(sock, "Hello")

      receive do
        {:converger, ^sock, %{"type" => "text", "data" => %{"text" => text}}} -> text
      end

  Frames for the application are sent to the owner (the caller of
  `start_link/1`, or `:owner`) as `{:converger, socket, frame}`: persistent
  frames in `seq` order, exactly once, plus transient frames (typing,
  presence, receipts, errors) and every `welcome`. When the socket ends for
  good the owner receives `{:converger_closed, socket, %{code: code, reason:
  reason}}` and the process stops.

  The socket reconnects with jittered exponential backoff, resumes from the
  watermark, answers gaps with `sync`, and re-sends unacknowledged sends with
  their original `clientId` (exactly-once persistence on the server).
  """

  use GenServer
  require Logger

  alias ConvergerClient.{Ack, Protocol.Session}

  @subprotocol "converger.v1"
  @path "/socket/converger/v1"
  @terminal [1008, 4400, 4401, 4403]

  @doc "The native endpoint URL for a REST base URL."
  @spec url(String.t()) :: String.t()
  def url(base_url) do
    uri = URI.parse(String.trim_trailing(base_url, "/"))
    scheme = %{"http" => "ws", "https" => "wss"}[uri.scheme] || uri.scheme
    URI.to_string(%{uri | scheme: scheme, path: (uri.path || "") <> @path})
  end

  @doc """
  Starts the socket.

  Options: `:client` or `:url`, `:token` (string or 0-arity function, called
  on every connect), `:conversation_id`, `:watermark`, `:owner` (default the
  caller), `:reconnect` (default true), `:max_retries` (default unlimited),
  `:backoff` (`{initial_ms, max_ms}`, default `{500, 30_000}`),
  `:connect_timeout` (ms, default 10_000).
  """
  def start_link(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Sends a `text` turn and waits for its ack. Options: `:client_id`, `:metadata`, `:reply_to`, `:timeout`."
  @spec send_text(GenServer.server(), String.t(), keyword()) ::
          {:ok, Ack.t()} | {:error, term()}
  def send_text(sock, text, opts \\ []), do: send_message(sock, "text", %{"text" => text}, opts)

  @doc "Sends a message frame of any type and waits for its ack (`{:error, %{\"code\" => ...}}` when refused)."
  @spec send_message(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, Ack.t()} | {:error, term()}
  def send_message(sock, type, data, opts \\ []) do
    client_id =
      opts[:client_id] ||
        "ex-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    frame =
      %{"type" => type, "clientId" => client_id, "data" => data}
      |> put_if("metadata", opts[:metadata])
      |> put_if("replyTo", opts[:reply_to] && %{"id" => opts[:reply_to]})

    GenServer.call(sock, {:send, frame}, Keyword.get(opts, :timeout, 30_000))
  end

  @doc "Sends a typing indicator."
  def typing(sock, typing?),
    do: GenServer.cast(sock, {:raw, %{"type" => "typing", "isTyping" => typing?}})

  @doc "Marks everything up to `watermark` as read."
  def read(sock, watermark),
    do: GenServer.cast(sock, {:raw, %{"type" => "read", "watermark" => watermark}})

  @doc "The current watermark."
  def watermark(sock), do: GenServer.call(sock, :watermark)

  @doc "Closes the socket."
  def close(sock), do: GenServer.stop(sock, :normal)

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  # ------------------------------------------------------------- GenServer

  @impl true
  def init(opts) do
    url =
      opts[:url] ||
        (opts[:client] && url(opts[:client].base_url)) ||
        raise ArgumentError, ":url or :client is required"

    state = %{
      url: URI.parse(url),
      token: Keyword.fetch!(opts, :token),
      owner: opts[:owner],
      reconnect: Keyword.get(opts, :reconnect, true),
      max_retries: opts[:max_retries],
      backoff: Keyword.get(opts, :backoff, {500, 30_000}),
      connect_timeout: Keyword.get(opts, :connect_timeout, 10_000),
      session: Session.new(Keyword.get(opts, :watermark, 0), opts[:conversation_id]),
      conn: nil,
      ref: nil,
      websocket: nil,
      status: nil,
      resp_headers: [],
      ready: false,
      welcomed: false,
      pending: %{},
      order: [],
      attempt: 0,
      auth_retries: 0,
      ping_interval: 30_000,
      generation: 0
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call({:send, frame}, from, state) do
    cid = frame["clientId"]

    state = %{
      state
      | pending: Map.put(state.pending, cid, {frame, from}),
        order: state.order ++ [cid]
    }

    state = if state.ready, do: push(state, frame), else: state
    {:noreply, state}
  end

  def handle_call(:watermark, _from, state), do: {:reply, state.session.watermark, state}

  @impl true
  def handle_cast({:raw, frame}, state),
    do: {:noreply, if(state.ready, do: push(state, frame), else: state)}

  @impl true
  def handle_info(:connect, state), do: connect(state)

  def handle_info({:scheduled_sync, gen}, %{generation: gen, ready: true} = state),
    do: {:noreply, push(state, Session.sync_frame(state.session))}

  def handle_info({:scheduled_sync, _}, state), do: {:noreply, state}

  def handle_info({:ping, gen}, %{generation: gen, ready: true} = state) do
    {:noreply, state |> push(%{"type" => "ping"}) |> schedule_ping()}
  end

  def handle_info({:ping, _}, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        handle_responses(%{state | conn: conn}, responses)

      {:error, conn, reason, _responses} ->
        disconnected(%{state | conn: conn}, nil, inspect(reason))

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.conn && state.websocket, do: send_ws(state, {:close, 1000, ""})
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end

  # ------------------------------------------------------------ connection

  defp connect(state) do
    %URI{scheme: scheme, host: host, port: port} = state.url
    http_scheme = if scheme == "wss", do: :https, else: :http
    ws_scheme = if scheme == "wss", do: :wss, else: :ws
    path = (state.url.path || "/") <> if(state.url.query, do: "?" <> state.url.query, else: "")

    with {:ok, token} <- resolve_token(state.token),
         {:ok, conn} <-
           Mint.HTTP.connect(http_scheme, host, port,
             protocols: [:http1],
             transport_opts: [timeout: state.connect_timeout]
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, [
             {"authorization", "Bearer " <> token},
             {"sec-websocket-protocol", @subprotocol},
             {"user-agent", "converger-elixir/#{ConvergerClient.version()}"}
           ]) do
      {:noreply,
       %{
         state
         | conn: conn,
           ref: ref,
           websocket: nil,
           status: nil,
           resp_headers: [],
           welcomed: false
       }}
    else
      {:error, reason} -> disconnected(state, nil, inspect(reason))
      {:error, conn, reason} -> disconnected(%{state | conn: conn}, nil, inspect(reason))
    end
  end

  defp resolve_token(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, token} -> {:ok, token}
      token when is_binary(token) -> {:ok, token}
      other -> {:error, {:token, other}}
    end
  end

  defp resolve_token(token) when is_binary(token), do: {:ok, token}

  defp handle_responses(state, responses) do
    Enum.reduce_while(responses, {:noreply, state}, fn response, {:noreply, state} ->
      case handle_response(response, state) do
        {:noreply, state} -> {:cont, {:noreply, state}}
        other -> {:halt, other}
      end
    end)
  end

  defp handle_response({:status, ref, status}, %{ref: ref} = state),
    do: {:noreply, %{state | status: status}}

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state),
    do: {:noreply, %{state | resp_headers: headers}}

  defp handle_response({:done, ref}, %{ref: ref, websocket: nil} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}
        {:noreply, push(state, Session.hello(state.session))}

      {:error, conn, reason} ->
        disconnected(%{state | conn: conn}, state.status, inspect(reason))
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, websocket: ws} = state) when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> handle_frames(%{state | websocket: ws}, frames)
      {:error, ws, reason} -> disconnected(%{state | websocket: ws}, nil, inspect(reason))
    end
  end

  defp handle_response(_other, state), do: {:noreply, state}

  defp handle_frames(state, frames) do
    Enum.reduce_while(frames, {:noreply, state}, fn frame, {:noreply, state} ->
      case handle_ws_frame(frame, state) do
        {:noreply, state} -> {:cont, {:noreply, state}}
        other -> {:halt, other}
      end
    end)
  end

  defp handle_ws_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{} = frame} -> {:noreply, handle_frame(state, frame)}
      _ -> {:noreply, state}
    end
  end

  defp handle_ws_frame({:ping, data}, state), do: {:noreply, send_ws(state, {:pong, data})}
  defp handle_ws_frame({:close, code, reason}, state), do: disconnected(state, code, reason)
  defp handle_ws_frame(_other, state), do: {:noreply, state}

  # --------------------------------------------------------------- frames

  defp handle_frame(state, frame) do
    type = frame["type"]

    {state, resolved?} =
      case type do
        "ack" -> {resolve(state, frame["clientId"], {:ok, Ack.from_map(frame)}), false}
        "error" -> resolve_error(state, frame["data"] || %{})
        _ -> {state, false}
      end

    {session, step} = Session.on_frame(state.session, frame)
    state = %{state | session: session}

    state =
      if type == "welcome" do
        state = %{
          state
          | ready: true,
            welcomed: true,
            attempt: 0,
            auth_retries: 0,
            generation: state.generation + 1
        }

        state = schedule_ping(%{state | ping_interval: ping_interval(frame)})

        Enum.reduce(state.order, state, fn cid, acc ->
          case acc.pending[cid] do
            {pending_frame, _from} -> push(acc, pending_frame)
            nil -> acc
          end
        end)
      else
        state
      end

    state = Enum.reduce(step.send, state, &push(&2, &1))

    Enum.each(step.schedule, fn {after_ms, _frame} ->
      Process.send_after(self(), {:scheduled_sync, state.generation}, after_ms)
    end)

    for delivered <- step.deliver, not (resolved? and type == "error") do
      send(state.owner, {:converger, self(), delivered})
    end

    state
  end

  defp resolve(state, cid, reply) do
    case Map.pop(state.pending, cid) do
      {nil, _} ->
        state

      {{_frame, from}, pending} ->
        GenServer.reply(from, reply)
        %{state | pending: pending, order: List.delete(state.order, cid)}
    end
  end

  defp resolve_error(state, %{"clientId" => cid} = data) do
    if Map.has_key?(state.pending, cid),
      do: {resolve(state, cid, {:error, data}), true},
      else: {state, false}
  end

  defp resolve_error(state, _data), do: {state, false}

  defp ping_interval(welcome) do
    idle = get_in(welcome, ["data", "limits", "idleTimeoutMs"])
    if is_integer(idle), do: max(div(idle, 2), 1_000), else: 30_000
  end

  defp schedule_ping(state) do
    Process.send_after(self(), {:ping, state.generation}, state.ping_interval)
    state
  end

  defp push(state, frame), do: send_ws(state, {:text, Jason.encode!(frame)})

  defp send_ws(%{conn: conn, websocket: ws, ref: ref} = state, frame)
       when conn != nil and ws != nil do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      %{state | conn: conn, websocket: ws}
    else
      {:error, %Mint.WebSocket{} = ws, _reason} -> %{state | websocket: ws}
      {:error, conn, _reason} -> %{state | conn: conn}
    end
  end

  defp send_ws(state, _frame), do: state

  # ------------------------------------------------------------ reconnect

  defp disconnected(state, code, reason) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    welcomed = state.welcomed

    state = %{
      state
      | conn: nil,
        websocket: nil,
        ref: nil,
        ready: false,
        welcomed: false,
        generation: state.generation + 1
    }

    reason = to_string(reason || "")

    cond do
      code == 4401 and is_function(state.token, 0) and state.auth_retries == 0 ->
        send(self(), :connect)
        {:noreply, %{state | auth_retries: 1}}

      not state.reconnect or code in @terminal ->
        stop(state, code, reason)

      true ->
        attempt = if welcomed, do: 0, else: state.attempt + 1

        if state.max_retries && attempt > state.max_retries do
          stop(state, code, "too many reconnect attempts: " <> reason)
        else
          Process.send_after(
            self(),
            :connect,
            retry_after(reason) || backoff(state.backoff, attempt)
          )

          {:noreply, %{state | attempt: attempt}}
        end
    end
  end

  defp stop(state, code, reason) do
    for {_cid, {_frame, from}} <- state.pending,
        do: GenServer.reply(from, {:error, {:closed, code, reason}})

    send(state.owner, {:converger_closed, self(), %{code: code, reason: reason}})
    {:stop, :normal, %{state | pending: %{}, order: []}}
  end

  defp backoff({initial, max}, attempt) do
    base = min(max, initial * Integer.pow(2, min(attempt, 20)))
    div(base, 2) + :rand.uniform(div(base, 2) + 1) - 1
  end

  defp retry_after(reason) do
    case Jason.decode(reason) do
      {:ok, %{"retryAfterMs" => ms}} when is_integer(ms) -> ms
      _ -> nil
    end
  end
end
