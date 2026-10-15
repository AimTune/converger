defmodule Converger.V1.Welcome do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Welcome",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :protocol, 1, type: :string
  field :compat, 2, repeated: true, type: :string
  field :scope, 3, proto3_optional: true, type: :string
  field :conversation_id, 4, proto3_optional: true, type: :string, json_name: "conversationId"
  field :user_id, 5, proto3_optional: true, type: :string, json_name: "userId"
  field :connection_id, 6, type: :string, json_name: "connectionId"
  field :watermark, 7, proto3_optional: true, type: :uint64
  field :pending, 8, repeated: true, type: Google.Protobuf.Struct
  field :expires_at, 9, proto3_optional: true, type: :int64, json_name: "expiresAt"
  field :capabilities, 10, type: Converger.V1.Capabilities
  field :limits, 11, type: Converger.V1.Limits
  field :channel_id, 12, proto3_optional: true, type: :string, json_name: "channelId"
end
