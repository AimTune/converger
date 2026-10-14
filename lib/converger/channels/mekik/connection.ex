defmodule Converger.Channels.Mekik.Connection do
  @moduledoc """
  One upstream mekik/1 connection: a `mekik` channel talking to its mekik
  server on behalf of one Converger conversation (Mode A of #64, ADR-0066).
  Started under `Converger.Channels.Mekik.Connections`; a WebSocket client
  (`Mint.WebSocket`).

  ## Handshake and resume

  The connection asserts its identity in the URL query string (`userId`,
  `conversationId`, `watermark`, for L7 affinity, mekik/1 section 1) and in a
  `hello` frame (frame wins), with the channel's `token` as `hello.token` and
  an `Authorization: Bearer` header, and the channel's `meta` as `hello.meta`.

  A mekik server mints its own `conversationId` on the first connect, so the
  pair it returns in `welcome` is recorded (`Converger.Channels.Mekik.Sessions`)
  and asserted on every later connect, with the highest mekik `seq` handled
  as the watermark: the server replays exactly what Converger missed. When
  the server hands back a different conversation (the asserted one was not
  resumable), the watermark is reset to 0, as mekik/1 requires.

  ## Frames from mekik

    * persistent frames (they carry `seq`): a `seq` at or below the watermark
      was handled already and is skipped (replays are not stored twice); a
      `text` with `from: "user"` is the fan-out echo of a turn Converger sent
      and is skipped; every other one (`text` from the bot, rich message
      frames, `tool_call`, `genui`, `interrupt`, `interrupt_resolved`,
      `skill`) is stored in the conversation as the channel's bot (config
      `bot_id`, default `"mekik"`) with `Converger.Activities.MessagePayload`,
      with the mekik channel as the source, so reply-back routing delivers it
      to the end user. The idempotency key names the mekik conversation and
      `seq`, so a store is exactly-once even when the watermark lagged;
    * transient `run`, `genui_components`, `skills` and `error` are relayed to
      the conversation's connections (`ConvergerWeb.Protocol.BotRelay.relay/2`);
      `run started` also shows the bot typing until the run ends, and a
      `typing` frame (chativa) sets it directly;
    * an `error` `unauthorized` followed by the close code 4401 (mekik/1
      section 7) fails pending deliveries permanently and waits
      `auth_retry_ms` before the next attempt.

  ## Lifecycle

  A lost connection is retried with exponential backoff and jitter. A
  connection without traffic for the channel's `idle_timeout_seconds` stops
  (`:normal`, not restarted); the next delivery starts a new one, which
  resumes from the recorded watermark.
  """

  use GenServer, restart: :transient

  require Logger

  alias Converger.{Activities, Conversations, Inbound}
  alias Converger.Activities.MessagePayload
  alias Converger.Channels.Adapters.Mekik
  alias Converger.Channels.DeliveryError
  alias Converger.Channels.Mekik.{Connections, Sessions}
  alias ConvergerWeb.ConversationSignals
  alias ConvergerWeb.Protocol.BotRelay

  @auth_close_code 4401
  @no_upgrade %{status: nil, headers: [], early: ""}
  # Fire-and-forget frames (forwarded bot-only frames) kept while connecting.
  @max_queue 100
  @watermark_flush_ms 1_000

  @doc "The `:global` name key of the connection of `channel_id` in `conversation_id`."
  def global_key(channel_id, conversation_id), do: {__MODULE__, channel_id, conversation_id}

  @doc """
  Start a connection. Options: `:channel` and `:conversation_id` (required),
  `:idle_timeout_ms` (default: the channel's `idle_timeout_seconds`).
  """
  def start_link(opts) do
    channel = Keyword.fetch!(opts, :channel)
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:global, global_key(channel.id, conversation_id)}
    )
  end

  @doc """
  Send `frame` upstream and wait until it is written to the socket (the
  connection is opened first when needed). `channel` is the current channel
  row: a changed URL, token or meta reconnects. Returns `{:ok, info}` or
  `{:error, reason}`.
  """
  def send_frame(pid, channel, frame) do
    GenServer.call(pid, {:send, channel, frame}, Mekik.setting(:call_timeout_ms))
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:connection_exit, reason}}
  end

  @doc "Queue `frame` for upstream without waiting."
  def forward(pid, frame), do: GenServer.cast(pid, {:forward, frame})

  @doc "The connection's phase, mekik conversation and watermark (operations, tests)."
  def info(pid), do: GenServer.call(pid, :info)

  ## Init

  @impl true
  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    # Stopped by the supervisor: terminate/2 records the watermark.
    Process.flag(:trap_exit, true)

    {:ok, _} = Registry.register(Connections.registry(), {channel.id, conversation_id}, nil)

    state = %{
      channel: channel,
      conversation_id: conversation_id,
      sender: Mekik.sender(channel),
      upstream: upstream_fingerprint(channel),
      idle_ms: Keyword.get_lazy(opts, :idle_timeout_ms, fn -> Mekik.idle_timeout_ms(channel) end),
      last_active: now(),
      phase: :init,
      generation: 0,
      conn: nil,
      websocket: nil,
      ref: nil,
      upgrade: @no_upgrade,
      session: nil,
      user_id: nil,
      watermark: 0,
      stored_watermark: 0,
      flush_scheduled?: false,
      queue: [],
      failures: 0,
      last_error: nil,
      typing: ConversationSignals.new_typing()
    }

    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    session = Sessions.get(state.channel.id, state.conversation_id)
    conversation = Conversations.get_conversation(state.conversation_id)

    state =
      case session do
        nil ->
          %{state | user_id: default_user_id(conversation, state.conversation_id)}

        session ->
          %{
            state
            | session: %{conversation_id: session.mekik_conversation_id},
              user_id: session.mekik_user_id,
              watermark: session.watermark,
              stored_watermark: session.watermark
          }
      end

    schedule_idle_check(state)
    {:noreply, connect(state)}
  end

  # The mekik userId: the conversation's participant (so mekik's per-user
  # store spans the participant's conversations), else the conversation.
  defp default_user_id(%{participant_id: id}, _conversation_id) when is_binary(id), do: id
  defp default_user_id(_conversation, conversation_id), do: "converger:" <> conversation_id

  ## Calls

  @impl true
  def handle_call({:send, channel, frame}, from, state) do
    state = state |> update_channel(channel) |> touch()

    case state.phase do
      :ready ->
        case push(state, frame) do
          {:ok, state} -> {:reply, {:ok, delivery_info(state)}, state}
          {:error, state, reason} -> {:reply, {:error, reason}, fail(state, reason)}
        end

      phase when phase in [:init, :connecting] ->
        {:noreply, enqueue(state, {from, frame})}

      :auth_failed ->
        {:reply, {:error, auth_error()}, state}

      :backoff ->
        {:reply, {:error, state.last_error || :not_connected}, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      phase: state.phase,
      mekik_conversation_id: state.session && state.session.conversation_id,
      user_id: state.user_id,
      watermark: state.watermark
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast({:forward, frame}, state) do
    state = touch(state)

    if state.phase == :ready do
      case push(state, frame) do
        {:ok, state} -> {:noreply, state}
        {:error, state, reason} -> {:noreply, fail(enqueue(state, {nil, frame}), reason)}
      end
    else
      {:noreply, enqueue(state, {nil, frame})}
    end
  end

  defp enqueue(state, {nil, _frame} = entry) do
    queue = [entry | state.queue]

    # Drop the oldest fire-and-forget frame beyond the cap; waiters stay.
    queue =
      if Enum.count(queue, &match?({nil, _}, &1)) > @max_queue do
        oldest = queue |> Enum.reverse() |> Enum.find(&match?({nil, _}, &1))
        List.delete(queue, oldest)
      else
        queue
      end

    %{state | queue: queue}
  end

  defp enqueue(state, entry), do: %{state | queue: [entry | state.queue]}

  defp delivery_info(state),
    do: %{mekik_conversation_id: state.session && state.session.conversation_id}

  # A changed URL, token or meta reconnects with the new values.
  defp update_channel(state, channel) do
    fingerprint = upstream_fingerprint(channel)
    state = %{state | channel: channel, sender: Mekik.sender(channel)}

    if fingerprint == state.upstream do
      state
    else
      reconnect(%{state | upstream: fingerprint, failures: 0}, 0)
    end
  end

  defp upstream_fingerprint(channel) do
    config = channel.config || %{}
    :erlang.phash2({config["url"], config["token"], config["meta"]})
  end

  ## Connecting

  defp connect(state) do
    generation = state.generation + 1
    state = %{state | generation: generation}

    case open(state) do
      {:ok, conn, ref} ->
        Process.send_after(
          self(),
          {:connect_timeout, generation},
          Mekik.setting(:connect_timeout_ms)
        )

        %{state | phase: :connecting, conn: conn, ref: ref, websocket: nil, upgrade: @no_upgrade}

      {:error, reason} ->
        Logger.warning("mekik connection failed",
          channel_id: state.channel.id,
          conversation_id: state.conversation_id,
          reason: inspect(reason)
        )

        fail(state, reason)
    end
  end

  defp open(state) do
    config = state.channel.config || %{}
    uri = URI.parse(config["url"] || "")
    {http, ws, port} = schemes(uri)

    with {:ok, conn} <-
           Mint.HTTP.connect(http, uri.host || "", port,
             protocols: [:http1],
             transport_opts: [timeout: Mekik.setting(:connect_timeout_ms)]
           ) do
      case Mint.WebSocket.upgrade(ws, conn, request_path(uri, state), auth_headers(config)) do
        {:ok, conn, ref} ->
          {:ok, conn, ref}

        {:error, conn, reason} ->
          Mint.HTTP.close(conn)
          {:error, reason}
      end
    end
  end

  defp schemes(%URI{scheme: "wss", port: port}), do: {:https, :wss, port || 443}
  defp schemes(%URI{port: port}), do: {:http, :ws, port || 80}

  defp request_path(uri, state) do
    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.merge(identity_query(state))
      |> URI.encode_query()

    (uri.path || "/") <> "?" <> query
  end

  defp auth_headers(%{"token" => token}) when is_binary(token) and token != "",
    do: [{"authorization", "Bearer " <> token}]

  defp auth_headers(_config), do: []

  # mekik/1 section 1: identity may travel in the query string (L7
  # affinity); the hello frame repeats it and wins.
  defp identity_query(state) do
    base = %{"userId" => state.user_id, "watermark" => Integer.to_string(state.watermark)}

    case state.session do
      %{conversation_id: id} -> Map.put(base, "conversationId", id)
      nil -> base
    end
  end

  defp hello(state) do
    config = state.channel.config || %{}

    %{"type" => "hello", "userId" => state.user_id, "watermark" => state.watermark}
    |> put_present("conversationId", state.session && state.session.conversation_id)
    |> put_present("token", non_empty(config["token"]))
    |> put_present("meta", non_empty_map(config["meta"]))
  end

  # Close the socket, fail the waiters and retry after a backoff.
  defp fail(state, reason) do
    state = %{close(state) | last_error: reason}
    {waiters, queue} = Enum.split_with(state.queue, fn {from, _} -> from != nil end)
    Enum.each(waiters, fn {from, _frame} -> GenServer.reply(from, {:error, reason}) end)

    state = %{state | queue: queue, phase: :backoff, failures: state.failures + 1}
    schedule_connect(state, backoff(state.failures))
  end

  defp fail_auth(state, message) do
    Logger.error("mekik server rejected the channel's credentials (#{@auth_close_code})",
      channel_id: state.channel.id,
      conversation_id: state.conversation_id,
      reason: message
    )

    error = auth_error()
    state = %{close(state) | last_error: error}
    {waiters, queue} = Enum.split_with(state.queue, fn {from, _} -> from != nil end)
    Enum.each(waiters, fn {from, _frame} -> GenServer.reply(from, {:error, error}) end)

    state = %{state | queue: queue, phase: :auth_failed, failures: state.failures + 1}
    schedule_connect(state, Mekik.setting(:auth_retry_ms))
  end

  defp auth_error,
    do:
      DeliveryError.permanent("mekik server rejected the token (close code #{@auth_close_code})")

  defp reconnect(state, delay) do
    state = close(state)
    schedule_connect(%{state | phase: :connecting}, delay)
  end

  defp schedule_connect(state, delay) do
    generation = state.generation + 1
    Process.send_after(self(), {:connect, generation}, delay)
    %{state | generation: generation}
  end

  defp close(%{conn: nil} = state), do: state

  defp close(state) do
    Mint.HTTP.close(state.conn)
    %{state | conn: nil, websocket: nil, ref: nil, upgrade: @no_upgrade}
  end

  # Exponential (base doubling up to the cap) with up to 50 % jitter.
  defp backoff(failures) do
    base = Mekik.setting(:backoff_base_ms)

    delay =
      min(base * Integer.pow(2, min(max(failures - 1, 0), 16)), Mekik.setting(:max_backoff_ms))

    delay + :rand.uniform(max(div(delay, 2), 1))
  end

  ## Messages

  @impl true
  def handle_info({:connect, generation}, %{generation: generation} = state),
    do: {:noreply, connect(%{state | generation: generation})}

  def handle_info({:connect, _stale}, state), do: {:noreply, state}

  def handle_info(
        {:connect_timeout, generation},
        %{generation: generation, phase: :connecting} = state
      ) do
    Logger.warning("mekik handshake timed out",
      channel_id: state.channel.id,
      conversation_id: state.conversation_id
    )

    {:noreply, fail(state, :handshake_timeout)}
  end

  def handle_info({:connect_timeout, _generation}, state), do: {:noreply, state}

  def handle_info(:idle_check, state) do
    if now() - state.last_active >= state.idle_ms and not Enum.any?(state.queue) do
      {:stop, :normal, state}
    else
      schedule_idle_check(state)
      {:noreply, state}
    end
  end

  # The supervisor stops us. (Exits of sockets, which are ports, are not:
  # a closed connection is handled as a stream error.)
  def handle_info({:EXIT, pid, reason}, state) when is_pid(pid), do: {:stop, reason, state}
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  def handle_info(:flush_watermark, state),
    do: {:noreply, flush_watermark(%{state | flush_scheduled?: false})}

  def handle_info(message, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, handle_responses(responses, %{state | conn: conn})}

      {:error, conn, reason, _responses} ->
        Logger.warning("mekik connection lost, reconnecting",
          channel_id: state.channel.id,
          conversation_id: state.conversation_id,
          reason: inspect(reason)
        )

        {:noreply, fail(%{state | conn: conn}, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_responses(responses, state) do
    Enum.reduce_while(responses, state, fn response, state ->
      generation = state.generation
      state = handle_response(response, state)
      # A reconnect was scheduled: the rest belongs to the old connection.
      if state.generation == generation, do: {:cont, state}, else: {:halt, state}
    end)
  end

  defp handle_response({:status, ref, status}, %{ref: ref} = state),
    do: %{state | upgrade: %{state.upgrade | status: status}}

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state),
    do: %{state | upgrade: %{state.upgrade | headers: headers}}

  defp handle_response({:done, ref}, %{ref: ref, websocket: nil} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.upgrade.status, state.upgrade.headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}

        case push(state, hello(state)) do
          {:ok, state} ->
            # Frames that came in the same packet as the 101 response.
            case state.upgrade.early do
              "" -> state
              data -> handle_response({:data, ref, data}, state)
            end

          {:error, state, reason} ->
            fail(state, reason)
        end

      {:error, conn, reason} ->
        Logger.warning("mekik WebSocket upgrade failed",
          channel_id: state.channel.id,
          conversation_id: state.conversation_id,
          reason: inspect(reason)
        )

        state = %{state | conn: conn}

        if match?(
             %Mint.WebSocket.UpgradeFailureError{status_code: code} when code in [401, 403],
             reason
           ),
           do: fail_auth(state, inspect(reason)),
           else: fail(state, reason)
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, websocket: websocket} = state)
       when not is_nil(websocket) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        handle_ws_frames(frames, %{state | websocket: websocket})

      {:error, websocket, reason} ->
        fail(%{state | websocket: websocket}, reason)
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref} = state),
    do: %{state | upgrade: %{state.upgrade | early: state.upgrade.early <> data}}

  defp handle_response({:error, ref, reason}, %{ref: ref} = state), do: fail(state, reason)

  defp handle_response(_response, state), do: state

  defp handle_ws_frames(frames, state) do
    Enum.reduce_while(frames, state, fn frame, state ->
      generation = state.generation
      state = handle_ws_frame(frame, state)
      if state.generation == generation, do: {:cont, state}, else: {:halt, state}
    end)
  end

  defp handle_ws_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => type} = frame} when is_binary(type) ->
        handle_frame(type, frame, touch(state))

      _ ->
        Logger.warning("mekik server sent an undecodable frame",
          channel_id: state.channel.id,
          conversation_id: state.conversation_id
        )

        state
    end
  end

  defp handle_ws_frame({:ping, data}, state) do
    case send_ws(state, {:pong, data}) do
      {:ok, state} -> state
      {:error, state, reason} -> fail(state, reason)
    end
  end

  defp handle_ws_frame({:close, @auth_close_code, reason}, state), do: fail_auth(state, reason)

  defp handle_ws_frame({:close, code, reason}, state) do
    Logger.info("mekik server closed the connection (#{code} #{reason}), reconnecting",
      channel_id: state.channel.id,
      conversation_id: state.conversation_id
    )

    fail(state, {:closed, code})
  end

  defp handle_ws_frame(_frame, state), do: state

  ## mekik frames

  defp handle_frame("welcome", %{"data" => %{} = data}, state) do
    mekik_conversation = data["conversationId"]
    user_id = if is_binary(data["userId"]), do: data["userId"], else: state.user_id

    if is_binary(mekik_conversation) do
      state |> adopt(mekik_conversation, user_id) |> ready()
    else
      fail(state, :invalid_welcome)
    end
  end

  defp handle_frame("error", %{"data" => %{"code" => "unauthorized"}} = frame, state) do
    # The close (4401) follows and fails the connection.
    Logger.warning("mekik server answered unauthorized: #{inspect(frame["data"]["message"])}",
      channel_id: state.channel.id,
      conversation_id: state.conversation_id
    )

    state
  end

  defp handle_frame("run", frame, state) do
    BotRelay.relay(state.conversation_id, frame)
    typing(state, get_in(frame, ["data", "status"]) == "started")
  end

  defp handle_frame("typing", %{"isTyping" => typing?}, state) when is_boolean(typing?),
    do: typing(state, typing?)

  defp handle_frame(type, frame, state) when type in ~w(genui_components skills error) do
    BotRelay.relay(state.conversation_id, frame)
    state
  end

  defp handle_frame(_type, %{"seq" => seq} = frame, %{phase: :ready} = state)
       when is_integer(seq) do
    cond do
      seq <= state.watermark -> state
      echo?(frame) -> advance(state, seq)
      true -> store(frame, seq, state)
    end
  end

  # Unknown transient frames (receivers ignore them, mekik/1 preamble).
  defp handle_frame(_type, _frame, state), do: state

  # The fan-out echo of a user turn: Converger already has the activity.
  defp echo?(%{"type" => "text", "from" => "user"}), do: true
  defp echo?(_frame), do: false

  defp adopt(state, mekik_conversation, user_id) do
    key = %{
      channel_id: state.channel.id,
      conversation_id: state.conversation_id,
      tenant_id: state.channel.tenant_id
    }

    case state.session do
      %{conversation_id: ^mekik_conversation} ->
        if user_id != state.user_id,
          do: Sessions.put(key, mekik_conversation, user_id, state.watermark)

        %{state | user_id: user_id}

      _other ->
        # A new mekik conversation (or the asserted one was not resumable):
        # its seq space starts over (mekik/1 section 1).
        Sessions.put(key, mekik_conversation, user_id, 0)

        %{
          state
          | session: %{conversation_id: mekik_conversation},
            user_id: user_id,
            watermark: 0,
            stored_watermark: 0
        }
    end
  end

  defp ready(state) do
    state = %{state | phase: :ready, failures: 0, last_error: nil}
    {entries, state} = {Enum.reverse(state.queue), %{state | queue: []}}

    Enum.reduce(entries, state, &flush_entry/2)
  end

  # After a failed send the rest waits for the next connection.
  defp flush_entry(entry, %{phase: :ready} = state) do
    {from, frame} = entry

    case push(state, frame) do
      {:ok, state} ->
        if from, do: GenServer.reply(from, {:ok, delivery_info(state)})
        state

      {:error, state, reason} ->
        fail(enqueue(state, entry), reason)
    end
  end

  defp flush_entry(entry, state), do: enqueue(state, entry)

  ## Storing

  defp store(frame, seq, state) do
    conversation_id = state.conversation_id
    client_id = "mekik:#{state.session.conversation_id}:#{seq}"
    key = BotRelay.client_key(state.sender, conversation_id, client_id)

    message =
      Map.merge(
        %{
          "type" => "message",
          "sender" => state.sender,
          "idempotency_key" => key,
          "metadata" => %{}
        },
        content_params(frame)
      )

    # Inbound de-duplicates per channel; a routed conversation belongs to
    # another channel, so a resend is recognised here first.
    result =
      case Activities.get_activity_by_idempotency_key(conversation_id, key) do
        nil -> Inbound.receive_message(state.channel, message, conversation_id: conversation_id)
        existing -> {:duplicate, existing}
      end

    case result do
      {tag, _activity} when tag in [:created, :duplicate] ->
        advance(state, seq)

      {:rejected, changeset} ->
        Logger.warning(
          "mekik #{frame["type"]} frame rejected: #{inspect(changeset.errors)}",
          channel_id: state.channel.id,
          conversation_id: conversation_id
        )

        advance(state, seq)

      {:error, :conversation_closed} ->
        advance(state, seq)

      {:error, reason} ->
        # Not stored: reconnect, the server replays it from the watermark.
        Logger.warning("mekik frame could not be stored, reconnecting",
          channel_id: state.channel.id,
          conversation_id: conversation_id,
          reason: inspect(reason)
        )

        fail(state, {:store_failed, reason})
    end
  end

  defp content_params(frame) do
    case MessagePayload.from_frame(frame, keep_id: true) do
      :plain ->
        %{"text" => frame["data"]["text"], "attachments" => frame["data"]["attachments"] || []}

      {:ok, type, payload} ->
        %{"message_type" => type, "payload" => payload}
    end
  end

  defp advance(state, seq) do
    state = %{state | watermark: max(state.watermark, seq)}

    if state.flush_scheduled? do
      state
    else
      Process.send_after(self(), :flush_watermark, @watermark_flush_ms)
      %{state | flush_scheduled?: true}
    end
  end

  defp flush_watermark(%{session: %{conversation_id: mekik_conversation}} = state)
       when state.watermark > state.stored_watermark do
    Sessions.advance(state.channel.id, state.conversation_id, mekik_conversation, state.watermark)
    %{state | stored_watermark: state.watermark}
  end

  defp flush_watermark(state), do: state

  ## Typing

  defp typing(state, typing?) do
    participant = %{id: state.sender, role: "bot"}

    %{
      state
      | typing:
          ConversationSignals.typing(state.typing, state.conversation_id, participant, typing?)
    }
  end

  ## Sending

  defp push(state, frame), do: send_ws(state, {:text, Jason.encode!(frame)})

  defp send_ws(%{websocket: nil} = state, _frame), do: {:error, state, :not_connected}

  # Two steps instead of one `with`: telling the failures apart by matching
  # on `%Mint.WebSocket{}` breaks its opacity (Dialyzer).
  defp send_ws(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> {:ok, %{state | conn: conn, websocket: websocket}}
          {:error, conn, reason} -> {:error, %{state | conn: conn, websocket: websocket}, reason}
        end

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}
    end
  end

  ## Helpers

  defp touch(state), do: %{state | last_active: now()}

  defp now, do: System.monotonic_time(:millisecond)

  defp schedule_idle_check(state),
    do: Process.send_after(self(), :idle_check, max(div(state.idle_ms, 4), 50))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_value), do: nil

  defp non_empty_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp non_empty_map(_value), do: nil

  @impl true
  def terminate(_reason, state) do
    state = flush_watermark(state)

    ConversationSignals.stop_typing(state.typing, state.conversation_id, %{
      id: state.sender,
      role: "bot"
    })

    if state.websocket, do: send_ws(state, {:close, 1000, ""})
    close(state)
    :ok
  end
end
