defmodule Converger.V1.ServerFrame do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.ServerFrame",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:frame, 0)

  field :welcome, 1, type: Converger.V1.Welcome, oneof: 0
  field :activity, 2, type: Converger.V1.Activity, oneof: 0
  field :ack, 3, type: Converger.V1.Ack, oneof: 0
  field :error, 4, type: Converger.V1.Error, oneof: 0

  field :delivery_status, 5,
    type: Converger.V1.DeliveryStatus,
    json_name: "deliveryStatus",
    oneof: 0

  field :typing, 6, type: Converger.V1.Typing, oneof: 0
  field :presence, 7, type: Converger.V1.Presence, oneof: 0
  field :heartbeat, 8, type: Converger.V1.Heartbeat, oneof: 0

  field :token_refreshed, 9,
    type: Converger.V1.TokenRefreshed,
    json_name: "tokenRefreshed",
    oneof: 0

  field :replay_truncated, 10,
    type: Converger.V1.ReplayTruncated,
    json_name: "replayTruncated",
    oneof: 0

  field :close, 11, type: Converger.V1.Close, oneof: 0
  field :raw, 15, type: Google.Protobuf.Struct, oneof: 0
end
