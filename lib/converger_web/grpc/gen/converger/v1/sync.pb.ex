defmodule Converger.V1.Sync do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Sync",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:position, 0)

  field :watermark, 1, type: :uint64, oneof: 0
  field :legacy_watermark, 2, type: :string, json_name: "legacyWatermark", oneof: 0
end
