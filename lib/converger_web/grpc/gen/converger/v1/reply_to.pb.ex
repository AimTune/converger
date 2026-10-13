defmodule Converger.V1.ReplyTo do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.ReplyTo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :id, 1, type: :string
  field :seq, 2, proto3_optional: true, type: :uint64
end
