defmodule Converger.V1.Typing do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Typing",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :is_typing, 1, type: :bool, json_name: "isTyping"
  field :from, 2, proto3_optional: true, type: :string
  field :sender, 3, type: Converger.V1.Sender
  field :seq, 4, proto3_optional: true, type: :uint64
  field :id, 5, proto3_optional: true, type: :string
  field :timestamp, 6, proto3_optional: true, type: :int64
end
