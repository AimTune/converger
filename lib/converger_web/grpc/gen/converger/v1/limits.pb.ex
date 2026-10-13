defmodule Converger.V1.Limits do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Limits",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :max_frame_bytes, 1, proto3_optional: true, type: :uint64, json_name: "maxFrameBytes"
  field :max_text_bytes, 2, proto3_optional: true, type: :uint64, json_name: "maxTextBytes"

  field :max_metadata_bytes, 3,
    proto3_optional: true,
    type: :uint64,
    json_name: "maxMetadataBytes"

  field :max_in_flight, 4, proto3_optional: true, type: :uint64, json_name: "maxInFlight"

  field :heartbeat_interval_ms, 5,
    proto3_optional: true,
    type: :uint64,
    json_name: "heartbeatIntervalMs"

  field :idle_timeout_ms, 6, proto3_optional: true, type: :uint64, json_name: "idleTimeoutMs"
  field :replay_batch, 7, proto3_optional: true, type: :uint64, json_name: "replayBatch"
  field :replay_max, 8, proto3_optional: true, type: :uint64, json_name: "replayMax"
  field :max_conversations, 9, proto3_optional: true, type: :uint64, json_name: "maxConversations"
end
