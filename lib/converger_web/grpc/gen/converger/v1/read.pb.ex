defmodule Converger.V1.Read do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Read",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :watermark, 1, type: :uint64
end
