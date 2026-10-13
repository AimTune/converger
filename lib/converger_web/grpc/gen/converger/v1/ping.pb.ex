defmodule Converger.V1.Ping do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Ping",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :nonce, 1, proto3_optional: true, type: :string
end
