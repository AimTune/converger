defmodule Converger.V1.Sender do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Sender",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :id, 1, type: :string
  field :role, 2, proto3_optional: true, type: :string
  field :name, 3, proto3_optional: true, type: :string
end
