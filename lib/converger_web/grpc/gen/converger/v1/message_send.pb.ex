defmodule Converger.V1.MessageSend do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.MessageSend",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:payload, 0)

  field :type, 1, type: :string
  field :client_id, 2, proto3_optional: true, type: :string, json_name: "clientId"
  field :text, 3, type: Converger.V1.TextData, oneof: 0
  field :data, 4, type: Google.Protobuf.Struct, oneof: 0
  field :metadata, 5, type: Google.Protobuf.Struct
  field :meta, 6, type: Google.Protobuf.Struct
  field :reply_to, 7, type: Converger.V1.ReplyTo, json_name: "replyTo"
  field :id, 8, proto3_optional: true, type: :string
  field :timestamp, 9, proto3_optional: true, type: :int64
end
