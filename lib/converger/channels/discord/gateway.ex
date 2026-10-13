defmodule Converger.Channels.Discord.Gateway do
  @moduledoc """
  The Discord Gateway connection of a `discord` channel in Gateway mode
  (`gateway: true`), run once in the cluster by
  `Converger.Channels.Consumers` (the `c:Converger.Channels.Broker.consumer_child_spec/1`
  of the Discord adapter). A WebSocket client (`Mint.WebSocket`) of the
  Gateway API v10, JSON encoding, no compression, one shard:

    * **Hello / heartbeat**: after `HELLO` (op 10) the first heartbeat
      (op 1, the last sequence number) is sent after `heartbeat_interval *
      jitter` (jitter in 0..1), then every `heartbeat_interval`. A heartbeat
      the Gateway asks for (op 1) is sent at once.
    * **Zombie detection**: when no `HEARTBEAT_ACK` (op 11) arrived since
      the previous heartbeat, the connection is considered dead: it is closed
      and resumed.
    * **Identify / resume**: a new session sends `IDENTIFY` (op 2, the bot
      token and the channel's intents); after a reconnect a known session is
      resumed (op 6, `session_id` and the last sequence number) on the
      `resume_gateway_url` of `READY`, so the events in between are replayed.
    * **Reconnect** (op 7) resumes at once; **invalid session** (op 9)
      resumes when `d` is true, else identifies again after 1 to 5 seconds.
      A closed socket or a close frame resumes, except close codes that
      invalidate the session (4007, 4009: identify again) and those no
      retry can fix (4004 authentication failed, 4010 to 4014: shard,
      version or intents), after which it waits `fatal_retry_ms` (default
      5 minutes) before it tries again. Failed connection attempts back off
      exponentially (1 s doubling, at most 60 s).
    * **Messages**: `MESSAGE_CREATE` events are parsed by
      `Converger.Channels.Adapters.Discord.parse_gateway_message/2` (the
      bot's own messages and other bots' are ignored) and handed to a linked
      `Converger.Channels.Discord.GatewayWorker`, which creates the
      activities (idempotency key `message:<id>`, so an event replayed by a
      resume is a duplicate).

  The Gateway has no acknowledgements: an event received while the worker
  cannot store it is retried in place and then dropped (logged and counted
  as `converger.broker.dead_lettered.count`), and events sent while no
  connection is open are recovered only through a resume.

  ## Configuration

      config :converger, Converger.Channels.Adapters.Discord,
        # operator / test override of the Gateway URL (default: GET /gateway/bot)
        gateway_url: "wss://gateway.discord.gg",
        fatal_retry_ms: 300_000
  """

  use GenServer

  require Logger

  alias Converger.Channels.Adapters.Discord
  alias Converger.Channels.Discord.GatewayWorker

  # Gateway opcodes.
  @dispatch 0
  @heartbeat 1
  @identify 2
  @resume 6
  @reconnect 7
  @invalid_session 9
  @hello 10
  @heartbeat_ack 11

  # Close codes after which reconnecting cannot help: authentication
  # failed, invalid shard, sharding required, invalid API version, invalid
  # or disallowed intents.
  @fatal_close_codes [4004, 4010, 4011, 4012, 4013, 4014]
  # Close codes that invalidate the session: invalid seq, session timed out.
  @new_session_close_codes [4007, 4009]

  @max_backoff_ms 60_000
  @no_upgrade %{status: nil, headers: [], early: ""}
  @connect_timeout_ms 15_000

  def child_spec(channel) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [channel]}}
  end

  def start_link(channel), do: GenServer.start_link(__MODULE__, channel)

  @impl true
  def init(channel) do
    Process.flag(:trap_exit, true)
    token = (channel.config || %{})["bot_token"]

    if is_binary(token) and token != "" do
      {:ok, worker} = GatewayWorker.start_link(channel)

      state = %{
        channel: channel,
        token: token,
        intents: Discord.gateway_intents(channel),
        worker: worker,
        generation: 0,
        conn: nil,
        websocket: nil,
        ref: nil,
        upgrade: @no_upgrade,
        seq: nil,
        session_id: nil,
        resume_url: nil,
        bot_user_id: nil,
        heartbeat_interval: nil,
        acked?: true,
        failures: 0
      }

      {:ok, state, {:continue, :connect}}
    else
      {:stop, {:invalid_config, "discord channel has no bot_token"}}
    end
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  ## Connecting

  defp connect(state) do
    resume? = resumable?(state)

    url_result =
      if resume?, do: {:ok, Discord.gateway_query(state.resume_url)}, else: gateway_url(state)

    with {:ok, url} <- url_result,
         {:ok, conn, ref} <- open(url) do
      %{state | conn: conn, ref: ref, websocket: nil, upgrade: @no_upgrade}
    else
      {:error, reason} ->
        Logger.warning("Discord Gateway connection failed",
          channel_id: state.channel.id,
          reason: inspect(reason)
        )

        schedule_reconnect(state, backoff(state.failures), resume?)
    end
  end

  defp gateway_url(state) do
    case Discord.gateway_url(state.channel) do
      {:ok, url} -> {:ok, url}
      {:error, reason} -> {:error, {:gateway_url, reason}}
    end
  end

  defp open(url) do
    uri = URI.parse(url)

    {http, ws} =
      if uri.scheme in ["wss", "https"], do: {:https, :wss}, else: {:http, :ws}

    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    with {:ok, conn} <-
           Mint.HTTP.connect(http, uri.host, uri.port,
             protocols: [:http1],
             transport_opts: [timeout: @connect_timeout_ms]
           ) do
      case Mint.WebSocket.upgrade(ws, conn, path, []) do
        {:ok, conn, ref} ->
          {:ok, conn, ref}

        {:error, conn, reason} ->
          Mint.HTTP.close(conn)
          {:error, reason}
      end
    end
  end

  defp resumable?(state), do: is_binary(state.session_id) and is_binary(state.resume_url)

  # Close the current connection and connect again after `delay`.
  # `resume?: false` forgets the session (a new IDENTIFY).
  defp schedule_reconnect(state, delay, resume?) do
    state = close(state)
    generation = state.generation + 1

    state =
      if resume?,
        do: state,
        else: %{state | session_id: nil, seq: nil, resume_url: nil}

    Process.send_after(self(), {:connect, generation}, delay)
    %{state | generation: generation, failures: state.failures + 1}
  end

  defp close(%{conn: nil} = state), do: state

  defp close(state) do
    Mint.HTTP.close(state.conn)
    %{state | conn: nil, websocket: nil, ref: nil, upgrade: @no_upgrade, heartbeat_interval: nil}
  end

  defp backoff(0), do: 0

  defp backoff(failures) do
    base = min(1_000 * Integer.pow(2, min(failures - 1, 10)), @max_backoff_ms)
    base + :rand.uniform(1_000)
  end

  ## Messages

  @impl true
  def handle_info({:connect, generation}, %{generation: generation} = state),
    do: {:noreply, connect(state)}

  def handle_info({:connect, _stale}, state), do: {:noreply, state}

  def handle_info({:heartbeat, generation}, %{generation: generation} = state) do
    if state.acked? do
      state = send_heartbeat(%{state | acked?: false})
      schedule_heartbeat(state, state.heartbeat_interval)
      {:noreply, state}
    else
      Logger.warning("Discord Gateway heartbeat not acknowledged, reconnecting",
        channel_id: state.channel.id
      )

      {:noreply, schedule_reconnect(state, 0, true)}
    end
  end

  def handle_info({:heartbeat, _stale}, state), do: {:noreply, state}

  def handle_info({:EXIT, worker, reason}, %{worker: worker} = state),
    do: {:stop, reason, state}

  # The consumer supervisor stops us. (Exits of sockets, which are ports,
  # are not: the closed connection is handled as a stream error.)
  def handle_info({:EXIT, pid, reason}, state) when is_pid(pid), do: {:stop, reason, state}

  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, handle_responses(responses, %{state | conn: conn})}

      {:error, conn, reason, _responses} ->
        Logger.warning("Discord Gateway connection lost, resuming",
          channel_id: state.channel.id,
          reason: inspect(reason)
        )

        {:noreply, schedule_reconnect(%{state | conn: conn}, backoff(state.failures), true)}

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
    case Mint.WebSocket.new(
           state.conn,
           ref,
           state.upgrade.status,
           state.upgrade.headers
         ) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}

        # Frames that came in the same packet as the 101 response (the
        # HELLO) are part of the upgrade response body.
        case state.upgrade.early do
          "" -> state
          data -> handle_response({:data, ref, data}, state)
        end

      {:error, conn, reason} ->
        Logger.warning("Discord Gateway WebSocket upgrade failed",
          channel_id: state.channel.id,
          reason: inspect(reason)
        )

        schedule_reconnect(%{state | conn: conn}, backoff(state.failures + 1), true)
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, websocket: websocket} = state)
       when not is_nil(websocket) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        handle_frames(frames, %{state | websocket: websocket})

      {:error, websocket, reason} ->
        Logger.warning("Discord Gateway frame error, resuming",
          channel_id: state.channel.id,
          reason: inspect(reason)
        )

        schedule_reconnect(%{state | websocket: websocket}, 0, true)
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref} = state),
    do: %{state | upgrade: %{state.upgrade | early: state.upgrade.early <> data}}

  defp handle_response({:error, ref, reason}, %{ref: ref} = state) do
    Logger.warning("Discord Gateway connection error, resuming",
      channel_id: state.channel.id,
      reason: inspect(reason)
    )

    schedule_reconnect(state, backoff(state.failures), true)
  end

  defp handle_response(_response, state), do: state

  defp handle_frames(frames, state) do
    Enum.reduce_while(frames, state, fn frame, state ->
      generation = state.generation
      state = handle_frame(frame, state)
      if state.generation == generation, do: {:cont, state}, else: {:halt, state}
    end)
  end

  defp handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"op" => op} = payload} ->
        handle_payload(op, payload, state)

      _ ->
        Logger.warning("Discord Gateway sent an undecodable payload",
          channel_id: state.channel.id
        )

        state
    end
  end

  defp handle_frame({:ping, data}, state), do: send_frame(state, {:pong, data})

  defp handle_frame({:close, code, reason}, state) do
    cond do
      code in @fatal_close_codes ->
        Logger.error("Discord Gateway closed the connection: #{code} #{reason}",
          channel_id: state.channel.id,
          reason: "close code #{code}"
        )

        schedule_reconnect(state, fatal_retry_ms(), false)

      code in @new_session_close_codes ->
        Logger.warning("Discord Gateway session invalidated (#{code}), identifying again",
          channel_id: state.channel.id
        )

        schedule_reconnect(state, backoff(state.failures), false)

      true ->
        Logger.info("Discord Gateway closed the connection (#{code}), resuming",
          channel_id: state.channel.id
        )

        schedule_reconnect(state, backoff(state.failures), true)
    end
  end

  defp handle_frame(_frame, state), do: state

  ## Gateway payloads

  defp handle_payload(@hello, %{"d" => %{"heartbeat_interval" => interval}}, state)
       when is_integer(interval) and interval > 0 do
    state = %{state | heartbeat_interval: interval, acked?: true}
    schedule_heartbeat(state, round(interval * :rand.uniform()))

    if resumable?(state) do
      send_payload(state, @resume, %{
        "token" => state.token,
        "session_id" => state.session_id,
        "seq" => state.seq
      })
    else
      send_payload(state, @identify, %{
        "token" => state.token,
        "intents" => state.intents,
        "properties" => %{
          "os" => os(),
          "browser" => "converger",
          "device" => "converger"
        }
      })
    end
  end

  defp handle_payload(@heartbeat_ack, _payload, state), do: %{state | acked?: true}

  defp handle_payload(@heartbeat, _payload, state), do: send_heartbeat(state)

  defp handle_payload(@reconnect, _payload, state) do
    Logger.info("Discord Gateway asked for a reconnect, resuming", channel_id: state.channel.id)
    schedule_reconnect(%{state | failures: 0}, 0, true)
  end

  defp handle_payload(@invalid_session, %{"d" => resumable}, state) do
    Logger.info(
      "Discord Gateway invalidated the session (#{if resumable == true, do: "resumable", else: "not resumable"})",
      channel_id: state.channel.id
    )

    if resumable == true,
      do: schedule_reconnect(state, 0, true),
      else: schedule_reconnect(state, 1_000 + :rand.uniform(4_000), false)
  end

  defp handle_payload(@dispatch, payload, state) do
    state = if is_integer(payload["s"]), do: %{state | seq: payload["s"]}, else: state
    dispatch(payload["t"], payload["d"] || %{}, state)
  end

  defp handle_payload(_op, _payload, state), do: state

  defp dispatch("READY", data, state) do
    Logger.info("Discord Gateway ready", channel_id: state.channel.id)

    %{
      state
      | session_id: data["session_id"],
        resume_url: data["resume_gateway_url"],
        bot_user_id: get_in(data, ["user", "id"]),
        failures: 0
    }
  end

  defp dispatch("RESUMED", _data, state) do
    Logger.info("Discord Gateway session resumed", channel_id: state.channel.id)
    %{state | failures: 0}
  end

  defp dispatch("MESSAGE_CREATE", data, state) do
    case Discord.parse_gateway_message(data, state.bot_user_id) do
      {:ok, message} ->
        GatewayWorker.process(
          state.worker,
          message,
          "gateway/#{data["channel_id"]}/#{data["id"]}"
        )

      :ignore ->
        :ok
    end

    state
  end

  defp dispatch(_event, _data, state), do: state

  ## Sending

  defp send_heartbeat(state), do: send_payload(state, @heartbeat, state.seq)

  defp send_payload(state, op, data),
    do: send_frame(state, {:text, Jason.encode!(%{"op" => op, "d" => data})})

  defp send_frame(%{websocket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      %{state | conn: conn, websocket: websocket}
    else
      {:error, _websocket_or_conn, reason} ->
        Logger.warning("Discord Gateway send failed, resuming",
          channel_id: state.channel.id,
          reason: inspect(reason)
        )

        schedule_reconnect(state, backoff(state.failures), true)
    end
  end

  defp schedule_heartbeat(state, delay),
    do: Process.send_after(self(), {:heartbeat, state.generation}, delay)

  defp fatal_retry_ms do
    Keyword.get(
      Application.get_env(:converger, Discord, []),
      :fatal_retry_ms,
      300_000
    )
  end

  defp os do
    {_family, name} = :os.type()
    Atom.to_string(name)
  end

  @impl true
  def terminate(_reason, state) do
    # Close with 1000 only when stopped for good (the session ends with it).
    if state.websocket, do: send_frame(state, {:close, 1000, ""})
    close(state)
    :ok
  end
end
