defmodule ConvergerWeb.Protocol do
  @moduledoc """
  Converger Protocol v1 (`converger/1`, docs/protocol/v1.md): shared settings
  for the transports that speak it.

  The frames themselves are built by `ConvergerWeb.Protocol.Frames`, encoded
  by `ConvergerWeb.Protocol.Codec`, and the replay/live ordering rules live in
  `ConvergerWeb.Protocol.Feed`; a connection's session is
  `ConvergerWeb.Protocol.Session`. The transports are the native WebSocket
  endpoint (`ConvergerWeb.ProtocolSocket`), the gRPC stream
  (`ConvergerWeb.GRPC`, ADR-0056) and the Server-Sent Events stream
  (`ConvergerWeb.ConvergerAPI.EventStreamController`).

  Limits are configured under `config :converger, ConvergerWeb.Protocol`:

      config :converger, ConvergerWeb.Protocol,
        heartbeat_interval_ms: 30_000,
        idle_timeout_ms: 60_000,
        replay_max: 10_000,
        max_conversations: 5_000

  The replay batch size is the existing `:ws_replay_limit` pagination setting.
  Frame size, message rate, backpressure and draining are the shared client
  WebSocket limits of `config :converger, :websocket` (`ConvergerWeb.SocketGuard`).
  """

  alias Converger.ConvergerAPI.Watermark

  @version "converger/1"
  @compat ["mekik/1"]

  @defaults [
    heartbeat_interval_ms: 30_000,
    idle_timeout_ms: 60_000,
    replay_max: 10_000,
    # Conversations one channel-scoped connection follows at once (section 10).
    max_conversations: 5_000
  ]

  @doc "The protocol version string, `\"converger/1\"`."
  def version, do: @version

  @doc "Other protocols this server is compatible with (`welcome.data.compat`)."
  def compat, do: @compat

  @doc "A protocol setting (see the module docs)."
  def config(key) when is_atom(key) do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc "The limits announced in `welcome.data.limits`."
  def limits do
    activity_limits = Converger.Activities.Activity.limits()

    %{
      "maxFrameBytes" => ConvergerWeb.SocketGuard.config(:max_frame_bytes),
      "maxTextBytes" => activity_limits[:max_text_bytes],
      "maxMetadataBytes" => activity_limits[:max_metadata_bytes],
      # Enforced on the Phoenix binding (ConvergerWeb.Protocol.InFlight). The
      # native endpoint processes sends one at a time, so at most one of its
      # sends is ever unacknowledged.
      "maxInFlight" => ConvergerWeb.Protocol.InFlight.limit(),
      "heartbeatIntervalMs" => config(:heartbeat_interval_ms),
      "idleTimeoutMs" => config(:idle_timeout_ms),
      "replayBatch" => Converger.Pagination.config(:ws_replay_limit),
      "replayMax" => config(:replay_max),
      "maxConversations" => config(:max_conversations)
    }
  end

  @doc """
  Parse a client watermark (section 6.5 of the spec).

  Accepts the integer seq, its decimal string form and, during the migration
  window, the pre-v1 opaque forms (`Converger.ConvergerAPI.Watermark`).
  Returns `{:ok, nil}` when absent, `{:ok, {:seq, n}}`,
  `{:ok, {:activity_id, id}}` or `{:error, :invalid_watermark}`.

  With `deprecation: metadata`, a valid opaque watermark is also reported as
  a use of the deprecated `:opaque_watermark` surface
  (`ConvergerWeb.Deprecation`), so operators can find the clients that still
  send one before those forms are dropped. Surfaces that still emit the
  opaque form (the legacy Phoenix `activitySet`) leave it out.
  """
  def parse_watermark(value, opts \\ [])
  def parse_watermark(nil, _opts), do: {:ok, nil}
  def parse_watermark("", _opts), do: {:ok, nil}
  def parse_watermark(seq, _opts) when is_integer(seq) and seq >= 0, do: {:ok, {:seq, seq}}

  def parse_watermark(value, opts) when is_binary(value) do
    if value =~ ~r/^(0|[1-9][0-9]{0,18})$/ do
      {:ok, {:seq, String.to_integer(value)}}
    else
      value |> Watermark.decode() |> report_opaque(opts[:deprecation])
    end
  end

  def parse_watermark(_value, _opts), do: {:error, :invalid_watermark}

  defp report_opaque({:ok, {_, _}} = result, metadata) when is_list(metadata) do
    ConvergerWeb.Deprecation.warn(:opaque_watermark, metadata)
    result
  end

  defp report_opaque(result, _metadata), do: result

  @doc """
  The integer watermark to hand back for a parsed `position` when a page is
  empty (the client is at the head): the seq itself, the seq of a legacy
  activity-id watermark's activity, or nil.
  """
  def watermark_seq(nil, _conversation_id), do: nil
  def watermark_seq({:seq, seq}, _conversation_id), do: seq

  def watermark_seq({:activity_id, id}, conversation_id) do
    case Converger.Activities.get_conversation_activity(conversation_id, id) do
      %{seq: seq} -> seq
      nil -> nil
    end
  end

  @doc "Whether `value` is a valid `clientId` (1 to 128 of `A-Z a-z 0-9 . _ : ~ -`)."
  def client_id?(value) when is_binary(value), do: value =~ ~r/^[A-Za-z0-9._:~-]{1,128}$/
  def client_id?(_value), do: false

  @doc "A fresh opaque id with the given prefix, for connections and minted user ids."
  def random_id(prefix),
    do: prefix <> "-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc "Milliseconds since the epoch of a `DateTime` (or `now` when nil)."
  def to_ms(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :millisecond)

  def to_ms(%NaiveDateTime{} = datetime),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> to_ms()

  def to_ms(nil), do: System.system_time(:millisecond)
end
