defmodule Converger.V1.DeliveryStatus do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.DeliveryStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :activity_id, 1, proto3_optional: true, type: :string, json_name: "activityId"
  field :seq, 2, proto3_optional: true, type: :uint64
  field :up_to_seq, 3, proto3_optional: true, type: :uint64, json_name: "upToSeq"
  field :channel_id, 4, proto3_optional: true, type: :string, json_name: "channelId"
  field :status, 5, type: :string
  field :by, 6, type: Converger.V1.Sender
  field :attempt, 7, proto3_optional: true, type: :uint32
  field :error, 8, type: Converger.V1.DeliveryError
  field :timestamp, 9, type: :int64
end
