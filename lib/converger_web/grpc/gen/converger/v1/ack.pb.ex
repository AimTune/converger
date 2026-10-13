defmodule Converger.V1.Ack do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Ack",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :client_id, 1, type: :string, json_name: "clientId"
  field :id, 2, type: :string
  field :seq, 3, type: :uint64
  field :timestamp, 4, type: :int64
  field :duplicate, 5, type: :bool
end
