defmodule Converger.V1.Heartbeat do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Heartbeat",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :timestamp, 1, type: :int64
  field :nonce, 2, proto3_optional: true, type: :string
  field :head_seq, 3, proto3_optional: true, type: :uint64, json_name: "headSeq"
end
