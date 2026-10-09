defmodule ConvergerWeb.ConvergerAPI.EventStreamController do
  @moduledoc """
  Server-Sent Events fallback for receiving a conversation, for networks
  that block WebSockets:

      GET /api/v1/converger/conversations/:conversation_id/events?watermark=N

  Every event is a Converger Protocol v1 frame (the same JSON as on the
  native WebSocket), with the frame `type` as the SSE event name. Persistent
  frames carry their `seq` as the SSE `id`, so a reconnecting `EventSource`
  sends it back as `Last-Event-ID` and resumes exactly after it (it takes
  precedence over `?watermark=`). Sending is done over REST
  (`POST .../activities`).

  The stream replays `seq > watermark` (bounded, see
  `ConvergerWeb.Protocol.Feed`), then pushes live frames, with a `heartbeat`
  frame every `heartbeatIntervalMs`. It ends with an `error` frame when the
  token expires (`token_expired`) or the channel is deactivated.

  Authentication: `Authorization: Bearer` or `?token=` (EventSource cannot
  set headers). An absent watermark replays the whole conversation, as on the
  WebSocket; an invalid one also starts from the beginning, as on REST.
  """

  use ConvergerWeb, :controller

  import ConvergerWeb.Helpers.Authorization, only: [authorize_conversation: 2]

  alias Converger.{Channels, Conversations}
  alias ConvergerWeb.Protocol
  alias ConvergerWeb.Protocol.{Feed, Frames}

  # Refusals are JSON (the pipeline has no `accepts`: EventSource asks for
  # text/event-stream).
  plug :put_format, "json"

  action_fallback ConvergerWeb.FallbackController

  def stream(conn, %{"conversation_id" => conversation_id} = params) do
    claims = conn.assigns.converger_claims
    channel_id = claims["channel_id"]

    with :ok <- authorize_conversation(claims, conversation_id),
         {:ok, _uuid} <- cast_id(conversation_id),
         %Conversations.Conversation{channel_id: ^channel_id} <-
           Conversations.get_conversation(conversation_id, claims["tenant_id"]) do
      start(conn, claims, conversation_id, params)
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # The request process is Bandit's connection process, which serves further
  # keep-alive requests after this one: everything the stream registers
  # (subscriptions, presence, timers) is undone when it ends, however it ends.
  defp start(conn, claims, conversation_id, params) do
    topic = "conversation:#{conversation_id}"
    # Subscribe before reading the head and the replay (see Feed).
    Phoenix.PubSub.subscribe(Converger.PubSub, topic)
    socket_id = track(claims, conversation_id)
    {:ok, heartbeat} = :timer.send_interval(Protocol.config(:heartbeat_interval_ms), :heartbeat)
    expiry = schedule_expiry(claims)

    try do
      stream(conn, claims, conversation_id, params)
    after
      :timer.cancel(heartbeat)
      if expiry, do: Process.cancel_timer(expiry)
      Phoenix.PubSub.unsubscribe(Converger.PubSub, topic)

      if socket_id do
        Phoenix.PubSub.unsubscribe(Converger.PubSub, socket_id)
        ConvergerWeb.Sockets.untrack_id(socket_id, claims["channel_id"])
      end

      flush()
    end
  end

  defp flush do
    receive do
      %Phoenix.Socket.Broadcast{} -> flush()
      :heartbeat -> flush()
      :token_expired -> flush()
    after
      0 -> :ok
    end
  end

  defp stream(conn, claims, conversation_id, params) do
    head = Conversations.get_conversation(conversation_id).last_seq
    user_id = claims["user_id"] || string(params["userId"])
    feed = Feed.new(conversation_id, user_id)

    {frames, feed} =
      case position(conn, params) do
        {:seq, seq} when seq > head ->
          message = "watermark #{seq} is above the head #{head}"
          {[Frames.error("invalid_watermark", message)], Feed.seek(feed, head)}

        position ->
          Feed.replay(feed, position, head)
      end

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      # Disable response buffering in nginx-style proxies.
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case chunk(conn, ["retry: 3000\n\n" | Enum.map(frames, &event/1)]) do
      {:ok, conn} -> loop(conn, %{feed: feed, claims: claims})
      {:error, _closed} -> conn
    end
  end

  defp loop(conn, state) do
    receive do
      %Phoenix.Socket.Broadcast{event: "new_activity", payload: activity} ->
        {frames, feed} = Feed.live(state.feed, activity)
        send_frames(conn, frames, %{state | feed: feed})

      %Phoenix.Socket.Broadcast{event: "disconnect"} ->
        finish(conn, disconnect_frames(state.claims))

      :heartbeat ->
        send_frames(conn, [Frames.heartbeat(state.feed.last_seq)], state)

      :token_expired ->
        finish(conn, [Frames.error("token_expired", "token expired, refresh it")])

      _other ->
        loop(conn, state)
    end
  end

  defp send_frames(conn, [], state), do: loop(conn, state)

  defp send_frames(conn, frames, state) do
    case chunk(conn, Enum.map(frames, &event/1)) do
      {:ok, conn} -> loop(conn, state)
      {:error, _closed} -> conn
    end
  end

  defp finish(conn, frames) do
    case chunk(conn, Enum.map(frames, &event/1)) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  defp disconnect_frames(claims) do
    case Channels.get_active_channel(claims["channel_id"], claims["tenant_id"]) do
      {:ok, _channel} -> []
      _ -> [Frames.error("channel_inactive", "channel deactivated")]
    end
  end

  # One SSE event per frame. Jason never emits raw newlines, so the frame is
  # a single `data:` line.
  defp event(%{"type" => type} = frame) do
    id =
      if is_integer(frame["seq"]), do: ["id: ", Integer.to_string(frame["seq"]), "\n"], else: []

    [id, "event: ", type, "\n", "data: ", Jason.encode_to_iodata!(frame), "\n\n"]
  end

  # Last-Event-ID (sent by a reconnecting EventSource) wins over ?watermark=.
  defp position(conn, params) do
    value =
      case get_req_header(conn, "last-event-id") do
        [id | _] when id != "" -> id
        _ -> params["watermark"]
      end

    case Protocol.parse_watermark(value) do
      {:ok, position} -> position
      {:error, _} -> nil
    end
  end

  defp track(claims, conversation_id) do
    socket_id =
      claims
      |> Map.put("conversation_id", claims["conversation_id"] || conversation_id)
      |> ConvergerWeb.Sockets.converger_socket_id()

    if socket_id do
      Phoenix.PubSub.subscribe(Converger.PubSub, socket_id)

      ConvergerWeb.Sockets.track_id(socket_id, claims["channel_id"], %{
        tenant_id: claims["tenant_id"],
        conversation_id: conversation_id,
        transport: "sse"
      })
    end

    socket_id
  end

  defp schedule_expiry(%{"exp" => exp}) when is_integer(exp) do
    delay = max(exp * 1000 - System.system_time(:millisecond), 0)
    Process.send_after(self(), :token_expired, delay)
  end

  defp schedule_expiry(_claims), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil
end
