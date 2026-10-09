defmodule ConvergerWeb.Protocol do
  @moduledoc """
  Converger Protocol v1 (`converger/1`, docs/protocol/v1.md): shared settings
  for the transports that speak it.

  The frames themselves are built by `ConvergerWeb.Protocol.Frames`, encoded
  by `ConvergerWeb.Protocol.Codec`, and the replay/live ordering rules live in
  `ConvergerWeb.Protocol.Feed`. The transports are the native WebSocket
  endpoint (`ConvergerWeb.ProtocolSocket`) and the Server-Sent Events stream
  (`ConvergerWeb.ConvergerAPI.EventStreamController`).

  Limits are configured under `config :converger, ConvergerWeb.Protocol`:

      config :converger, ConvergerWeb.Protocol,
        heartbeat_interval_ms: 30_000,
        idle_timeout_ms: 60_000,
        replay_max: 10_000

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
    replay_max: 10_000
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
      # Sends are processed one at a time per connection, so at most one is
      # ever unacknowledged; the announced value is the protocol default.
      "maxInFlight" => 32,
      "heartbeatIntervalMs" => config(:heartbeat_interval_ms),
      "idleTimeoutMs" => config(:idle_timeout_ms),
      "replayBatch" => Converger.Pagination.config(:ws_replay_limit),
      "replayMax" => config(:replay_max)
    }
  end

  @doc """
  Parse a client watermark (section 6.5 of the spec).

  Accepts the integer seq, its decimal string form and, during the migration
  window, the pre-v1 opaque forms (`Converger.ConvergerAPI.Watermark`).
  Returns `{:ok, nil}` when absent, `{:ok, {:seq, n}}`,
  `{:ok, {:activity_id, id}}` or `{:error, :invalid_watermark}`.
  """
  def parse_watermark(nil), do: {:ok, nil}
  def parse_watermark(""), do: {:ok, nil}
  def parse_watermark(seq) when is_integer(seq) and seq >= 0, do: {:ok, {:seq, seq}}

  def parse_watermark(value) when is_binary(value) do
    if value =~ ~r/^(0|[1-9][0-9]{0,18})$/ do
      {:ok, {:seq, String.to_integer(value)}}
    else
      Watermark.decode(value)
    end
  end

  def parse_watermark(_value), do: {:error, :invalid_watermark}

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
