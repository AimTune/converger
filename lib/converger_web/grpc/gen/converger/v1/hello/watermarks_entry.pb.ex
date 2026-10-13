defmodule Converger.V1.Hello.WatermarksEntry do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Hello.WatermarksEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :uint64
end
