defmodule Converger.V1.Activity do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Activity",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:payload, 0)

  field :type, 1, type: :string
  field :id, 2, type: :string
  field :seq, 3, type: :uint64
  field :from, 4, type: :string
  field :sender, 5, type: Converger.V1.Sender
  field :text, 6, type: Converger.V1.TextData, oneof: 0
  field :data, 7, type: Google.Protobuf.Struct, oneof: 0
  field :timestamp, 8, type: :int64
  field :metadata, 9, type: Google.Protobuf.Struct
  field :client_id, 10, proto3_optional: true, type: :string, json_name: "clientId"
  field :reply_to, 11, type: Converger.V1.ReplyTo, json_name: "replyTo"
  field :actions, 12, repeated: true, type: Google.Protobuf.Struct
end
