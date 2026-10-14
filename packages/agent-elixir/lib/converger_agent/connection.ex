defmodule ConvergerAgent.Connection do
  @moduledoc false
  # The connection process of an agent: owns the Mint WebSocket (active mode),
  # keeps the per-conversation turn queues, the sends waiting for their ack,
  # the asks waiting for their answer and the watermarks. Turn handlers run in
  # tasks of a Task.Supervisor linked to this process, one task per busy
  # conversation.

  use GenServer
  require Logger

  alias ConvergerAgent.{Ack, CloseError, Error, HandlerError, Reply, Turn}

  @subprotocol "converger.v1"
  @terminal [1008, 4400, 4401, 4403]
  @not_turns ~w(typing presence deliveryStatus event conversationUpdate run genui_components skills heartbeat replayTruncated)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  # ------------------------------------------------------------- GenServer

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    handler = Keyword.fetch!(opts, :handler)

    cond do
      is_function(handler, 2) -> :ok
      is_atom(handler) and Code.ensure_loaded?(handler) -> :ok
      true -> raise ArgumentError, ":handler must be a module or a 2-arity function"
    end

    {:ok, task_sup} = Task.Supervisor.start_link()

    state = %{
      url: URI.parse(Keyword.fetch!(opts, :url)),
      token: Keyword.fetch!(opts, :token),
      handler: handler,
      on_error: opts[:on_error],
      group: opts[:group],
      user_id: opts[:user_id],
      headers: Keyword.get(opts, :headers, []),
      backoff_initial: Keyword.get(opts, :backoff_initial, 500),
      backoff_max: Keyword.get(opts, :backoff_max, 30_000),
      ack_timeout: Keyword.get(opts, :ack_timeout, 30_000),
      connect_timeout: Keyword.get(opts, :connect_timeout, 10_000),
      shutdown_timeout: Keyword.get(opts, :shutdown_timeout, 5_000),
      marks: Map.new(Keyword.get(opts, :watermarks, %{})),
      task_sup: task_sup,
      # the live connection
      conn: nil,
      ref: nil,
      websocket: nil,
      status: nil,
      resp_headers: [],
      welcomed: false,
      idle_ms: 60_000,
      generation: 0,
      attempt: 0,
      auth_retried: false,
      last_error: nil,
      # outgoing frames
      n: 0,
      pending: %{},
      backlog: [],
      asks: %{},
      # turns
      queues: %{},
      tasks: %{},
      runs: %{}
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call({:send, conv, frame}, from, state) do
    cid = frame["clientId"]
    {n, state} = next_n(state)
    env = envelope(conv, frame)
    timer = Process.send_after(self(), {:ack_timeout, cid}, state.ack_timeout)
    entry = %{n: n, env: env, from: from, timer: timer}
    state = %{state | pending: Map.put(state.pending, cid, entry)}
    state = if state.welcomed, do: elem(push(state, env), 1), else: state
    {:noreply, state}
  end

  def handle_call({:frame, conv, frame}, _from, state),
    do: {:reply, :ok, write_frame(state, conv, frame)}

  def handle_call({:ask, run, conv, data, timeout}, from, state) do
    {count, state} = ask_count(state, run)
    id = "ask/" <> Reply.random_id() <> "#" <> Integer.to_string(count)

    timer =
      if timeout == :infinity,
        do: nil,
        else: Process.send_after(self(), {:ask_timeout, id}, timeout)

    state = %{state | asks: Map.put(state.asks, id, %{from: from, timer: timer})}
    frame = %{"type" => "interrupt", "id" => id, "data" => data}
    {:noreply, write_frame(state, conv, frame)}
  end

  def handle_call({:end_run, run, status}, _from, state),
    do: {:reply, :ok, end_run(state, run, status)}

  def handle_call(:watermarks, _from, state), do: {:reply, state.marks, state}

  @impl true
  def handle_info(:connect, state), do: connect(state)

  def handle_info({:ping, gen}, %{generation: gen, welcomed: true} = state) do
    {_, state} = push(state, %{"type" => "ping"})
    {:noreply, schedule_ping(state)}
  end

  def handle_info({:ping, _}, state), do: {:noreply, state}

  def handle_info({:ack_timeout, cid}, state) do
    case Map.pop(state.pending, cid) do
      {nil, _} ->
        {:noreply, state}

      {entry, pending} ->
        GenServer.reply(entry.from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:ask_timeout, id}, state) do
    case Map.pop(state.asks, id) do
      {nil, _} ->
        {:noreply, state}

      {ask, asks} ->
        GenServer.reply(ask.from, {:error, :timeout})
        {:noreply, %{state | asks: asks}}
    end
  end

  def handle_info({:DOWN, mref, :process, _pid, reason}, state) do
    case Map.pop(state.tasks, mref) do
      {nil, _} ->
        {:noreply, state}

      {{conv, run}, tasks} ->
        state = %{state | tasks: tasks}
        # A task killed from outside never finished its run.
        state = if reason == :normal, do: state, else: end_run(state, run, "error")
        state = %{state | runs: Map.delete(state.runs, run)}
        {:noreply, next_turn(state, conv)}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{task_sup: pid} = state),
    do: {:stop, reason, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

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
    state = fail_all(state, {:error, :stopped})

    if state.conn do
      if state.websocket, do: send_ws(state, {:close, 1000, ""})
      Mint.HTTP.close(state.conn)
    end

    # Running handlers get {:error, :stopped} from every Reply call and are
    # given shutdown_timeout to return; the Task.Supervisor (linked) then
    # stops whatever is left.
    drain(state.tasks, System.monotonic_time(:millisecond) + state.shutdown_timeout)
    :ok
  end

  defp drain(tasks, _deadline) when map_size(tasks) == 0, do: :ok

  defp drain(tasks, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, mref, :process, _, _} ->
        drain(Map.delete(tasks, mref), deadline)

      {:"$gen_call", from, _request} ->
        GenServer.reply(from, {:error, :stopped})
        drain(tasks, deadline)
    after
      timeout -> :ok
    end
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
           Mint.WebSocket.upgrade(
             ws_scheme,
             conn,
             path,
             [
               {"authorization", "Bearer " <> token},
               {"sec-websocket-protocol", @subprotocol},
               {"user-agent", "converger-agent-elixir/#{ConvergerAgent.version()}"}
             ] ++ state.headers
           ) do
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
      {:error, {:token, _} = reason} ->
        report(state, reason)
        disconnected(state, nil, inspect(reason))

      {:error, reason} ->
        disconnected(state, nil, inspect(reason))

      {:error, conn, reason} ->
        disconnected(%{state | conn: conn}, nil, inspect(reason))
    end
  end

  defp resolve_token(token) when is_binary(token), do: {:ok, token}
  defp resolve_token(fun) when is_function(fun, 0), do: token_result(fun.())
  defp resolve_token({m, f, a}), do: token_result(apply(m, f, a))

  defp token_result({:ok, token}) when is_binary(token), do: {:ok, token}
  defp token_result(token) when is_binary(token), do: {:ok, token}
  defp token_result(other), do: {:error, {:token, other}}

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
        {_, state} = push(state, hello(state))
        {:noreply, state}

      {:error, conn, reason} ->
        disconnected(%{state | conn: conn}, nil, inspect(reason))
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, websocket: ws} = state) when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> handle_ws_frames(%{state | websocket: ws}, frames)
      {:error, ws, reason} -> disconnected(%{state | websocket: ws}, nil, inspect(reason))
    end
  end

  defp handle_response(_other, state), do: {:noreply, state}

  defp handle_ws_frames(state, frames) do
    Enum.reduce_while(frames, {:noreply, state}, fn frame, {:noreply, state} ->
      case handle_ws_frame(frame, state) do
        {:noreply, state} -> {:cont, {:noreply, state}}
        other -> {:halt, other}
      end
    end)
  end

  defp handle_ws_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{} = message} -> {:noreply, handle_message(state, message)}
      _ -> {:noreply, state}
    end
  end

  defp handle_ws_frame({:ping, data}, state), do: {:noreply, send_ws(state, {:pong, data})}
  defp handle_ws_frame({:close, code, reason}, state), do: disconnected(state, code, reason)
  defp handle_ws_frame(_other, state), do: {:noreply, state}

  defp hello(state) do
    %{"type" => "hello", "protocol" => "converger/1"}
    |> put_if("group", state.group)
    |> put_if("userId", state.user_id)
    |> put_if("watermarks", if(map_size(state.marks) > 0, do: state.marks))
  end

  # ------------------------------------------------------------ messages

  # Bare frames carry a type; conversation frames are envelopes without one.
  defp handle_message(state, %{"type" => "welcome"} = welcome) do
    if state.welcomed, do: state, else: welcomed(state, welcome)
  end

  defp handle_message(state, %{"type" => "error"} = frame) do
    error = Error.from_frame(nil, frame)
    report(state, error)
    %{state | last_error: error}
  end

  defp handle_message(state, %{"type" => _}), do: state

  defp handle_message(%{welcomed: true} = state, %{"conversationId" => id, "frame" => frame})
       when is_binary(id) and id != "" and is_map(frame),
       do: dispatch(state, id, frame)

  defp handle_message(state, _message), do: state

  # Flushes, in their original order, the sends not yet acked and the frames
  # written while disconnected.
  defp welcomed(state, welcome) do
    idle =
      case get_in(welcome, ["data", "limits", "idleTimeoutMs"]) do
        ms when is_integer(ms) and ms > 0 -> ms
        _ -> state.idle_ms
      end

    state = %{state | welcomed: true, idle_ms: idle, generation: state.generation + 1}
    state = schedule_ping(state)

    out =
      (state.backlog ++ Enum.map(state.pending, fn {_cid, e} -> {e.n, e.env} end))
      |> Enum.sort_by(&elem(&1, 0))

    state = %{state | backlog: []}

    # A failed write keeps the frame: pending sends stay pending, the others
    # go back to the backlog for the next connection.
    Enum.reduce(out, state, fn {_n, env} = item, state ->
      case push(state, env) do
        {:ok, state} ->
          state

        {:error, state} ->
          if Map.has_key?(state.pending, env["frame"]["clientId"]),
            do: state,
            else: %{state | backlog: state.backlog ++ [item]}
      end
    end)
  end

  defp dispatch(state, id, frame) do
    type = frame["type"]
    seq = frame["seq"]

    if is_integer(seq) and type != "ack" and seq <= Map.get(state.marks, id, 0) do
      # a duplicate (replay overlap)
      state
    else
      state =
        if is_integer(seq) and type != "ack",
          do: %{state | marks: Map.put(state.marks, id, seq)},
          else: state

      handle_frame(state, id, type, frame)
    end
  end

  defp handle_frame(state, _id, "ack", frame) do
    case Map.pop(state.pending, frame["clientId"]) do
      {nil, _} ->
        state

      {entry, pending} ->
        Process.cancel_timer(entry.timer)
        GenServer.reply(entry.from, {:ok, Ack.from_frame(frame)})
        %{state | pending: pending}
    end
  end

  defp handle_frame(state, id, "error", frame) do
    error = Error.from_frame(id, frame)

    case error.client_id && Map.pop(state.pending, error.client_id) do
      {%{} = entry, pending} ->
        Process.cancel_timer(entry.timer)
        GenServer.reply(entry.from, {:error, error})
        %{state | pending: pending}

      _ ->
        report(state, error)
        state
    end
  end

  defp handle_frame(state, id, "resume", frame) do
    answers = if is_map(frame["answers"]), do: frame["answers"], else: %{}

    Enum.reduce(answers, state, fn {interrupt_id, answer}, state ->
      case Map.pop(state.asks, interrupt_id) do
        {nil, _} ->
          report(state, %Error{
            code: "unknown_interrupt",
            message: "an answer to an interrupt this agent is not waiting for: " <> interrupt_id,
            conversation_id: id
          })

          state

        {ask, asks} ->
          if ask.timer, do: Process.cancel_timer(ask.timer)
          GenServer.reply(ask.from, {:ok, interrupt_id, answer})
          %{state | asks: asks}
      end
    end)
  end

  defp handle_frame(state, id, type, %{"from" => "user", "seq" => seq} = frame)
       when is_binary(type) and type not in @not_turns and is_integer(seq) do
    enqueue(state, Turn.from_frame(id, frame))
  end

  defp handle_frame(state, _id, _type, _frame), do: state

  # ------------------------------------------------------------ turns

  defp enqueue(state, %Turn{conversation_id: conv} = turn) do
    case state.queues do
      %{^conv => queue} ->
        %{state | queues: Map.put(state.queues, conv, :queue.in(turn, queue))}

      _ ->
        start_turn(%{state | queues: Map.put(state.queues, conv, :queue.new())}, turn)
    end
  end

  defp next_turn(state, conv) do
    case :queue.out(Map.fetch!(state.queues, conv)) do
      {{:value, turn}, queue} ->
        start_turn(%{state | queues: Map.put(state.queues, conv, queue)}, turn)

      {:empty, _} ->
        %{state | queues: Map.delete(state.queues, conv)}
    end
  end

  defp start_turn(state, turn) do
    run = make_ref()
    reply = %Reply{conn: self(), conversation_id: turn.conversation_id, run: run}
    state = write_frame(state, turn.conversation_id, run_frame("started"))
    handler = state.handler
    on_error = state.on_error

    {:ok, pid} =
      Task.Supervisor.start_child(state.task_sup, fn ->
        run_turn(handler, on_error, turn, reply)
      end)

    mref = Process.monitor(pid)

    %{
      state
      | tasks: Map.put(state.tasks, mref, {turn.conversation_id, run}),
        runs: Map.put(state.runs, run, %{conv: turn.conversation_id, ended: false, asks: 0})
    }
  end

  # Runs in the turn's task.
  defp run_turn(handler, on_error, turn, reply) do
    result =
      try do
        case invoke(handler, turn, reply) do
          {:error, reason} -> {:error_tuple, reason, nil}
          _ -> :ok
        end
      catch
        kind, reason -> {kind, reason, __STACKTRACE__}
      end

    case result do
      :ok ->
        Reply.end_run(reply)

      {kind, reason, stacktrace} ->
        # {:error, :stopped}: the agent is stopping, nothing to report.
        with :ok <- Reply.call(reply.conn, {:end_run, reply.run, "error"}) do
          notify(handler, on_error, %HandlerError{
            conversation_id: turn.conversation_id,
            turn_id: turn.id,
            kind: kind,
            reason: reason,
            stacktrace: stacktrace
          })
        end
    end
  end

  defp invoke(fun, turn, reply) when is_function(fun, 2), do: fun.(turn, reply)
  defp invoke(mod, turn, reply), do: mod.handle_turn(turn, reply)

  defp end_run(state, run, status) do
    case state.runs do
      %{^run => %{ended: false} = r} ->
        state = %{state | runs: Map.put(state.runs, run, %{r | ended: true})}
        write_frame(state, r.conv, run_frame(status))

      _ ->
        state
    end
  end

  defp ask_count(state, run) do
    case state.runs do
      %{^run => r} -> {r.asks, %{state | runs: Map.put(state.runs, run, %{r | asks: r.asks + 1})}}
      _ -> {0, state}
    end
  end

  defp run_frame(status), do: %{"type" => "run", "data" => %{"status" => status}}

  # ------------------------------------------------------------ writing

  # Writes a frame without an ack, or keeps it for the next connection
  # (typing is dropped while disconnected).
  defp write_frame(state, conv, frame) do
    {n, state} = next_n(state)
    env = envelope(conv, frame)

    cond do
      state.welcomed ->
        case push(state, env) do
          {:ok, state} -> state
          {:error, state} -> keep(state, n, env, frame)
        end

      true ->
        keep(state, n, env, frame)
    end
  end

  defp keep(state, _n, _env, %{"type" => "typing"}), do: state
  defp keep(state, n, env, _frame), do: %{state | backlog: state.backlog ++ [{n, env}]}

  defp envelope(conv, frame), do: %{"conversationId" => conv, "frame" => frame}

  defp next_n(state), do: {state.n + 1, %{state | n: state.n + 1}}

  defp push(state, frame) do
    case send_ws(state, {:text, Jason.encode!(frame)}) do
      {:ok, state} -> {:ok, state}
      {:error, state} -> {:error, state}
    end
  end

  defp send_ws(%{conn: conn, websocket: ws, ref: ref} = state, frame)
       when conn != nil and ws != nil do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, %{state | conn: conn, websocket: ws}}
    else
      {:error, %Mint.WebSocket{} = ws, _reason} -> {:error, %{state | websocket: ws}}
      {:error, conn, _reason} -> {:error, %{state | conn: conn}}
    end
  end

  defp send_ws(state, _frame), do: {:error, state}

  defp schedule_ping(state) do
    Process.send_after(self(), {:ping, state.generation}, max(div(state.idle_ms, 2), 1))
    state
  end

  # ------------------------------------------------------------ reconnect

  defp disconnected(state, code, reason) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    welcomed = state.welcomed
    last = state.last_error
    reason = to_string(reason || "")

    state = %{
      state
      | conn: nil,
        websocket: nil,
        ref: nil,
        welcomed: false,
        last_error: nil,
        generation: state.generation + 1,
        # a welcomed connection breaks a run of 4401s
        auth_retried: state.auth_retried and not welcomed
    }

    cond do
      code == 4401 and not state.auth_retried ->
        # One immediate retry lets a token function hand out a fresh token.
        send(self(), :connect)
        {:noreply, %{state | auth_retried: true}}

      code in @terminal ->
        error = %CloseError{code: code, reason: reason, last_error: last}
        report(state, error)
        state = fail_all(state, {:error, error})
        {:stop, {:shutdown, {:closed, code, last}}, state}

      true ->
        attempt = if welcomed, do: 1, else: state.attempt + 1
        delay = retry_after(reason) || backoff(state, attempt)
        Process.send_after(self(), :connect, delay)
        {:noreply, %{state | attempt: attempt}}
    end
  end

  defp fail_all(state, reply) do
    for {_cid, entry} <- state.pending do
      Process.cancel_timer(entry.timer)
      GenServer.reply(entry.from, reply)
    end

    for {_id, ask} <- state.asks do
      if ask.timer, do: Process.cancel_timer(ask.timer)
      GenServer.reply(ask.from, reply)
    end

    %{state | pending: %{}, asks: %{}}
  end

  defp backoff(state, attempt) do
    d = min(state.backoff_initial * Integer.pow(2, min(attempt - 1, 20)), state.backoff_max)
    half = div(d, 2)
    half + :rand.uniform(half + 1) - 1
  end

  defp retry_after(reason) do
    case Jason.decode(reason) do
      {:ok, %{"retryAfterMs" => ms}} when is_integer(ms) and ms >= 0 -> ms
      _ -> nil
    end
  end

  # ------------------------------------------------------------ errors

  defp report(state, error), do: notify(state.handler, state.on_error, error)

  defp notify(handler, on_error, error) do
    cond do
      is_function(on_error, 1) ->
        on_error.(error)

      is_atom(handler) and function_exported?(handler, :handle_error, 1) ->
        handler.handle_error(error)

      true ->
        log(error)
    end
  rescue
    e -> Logger.error("converger agent: error callback raised: " <> Exception.message(e))
  end

  defp log({:token, _} = reason), do: Logger.warning("converger agent: token: #{inspect(reason)}")
  defp log(e) when is_exception(e), do: Logger.warning(Exception.message(e))
  defp log(other), do: Logger.warning("converger agent: #{inspect(other)}")

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)
end
