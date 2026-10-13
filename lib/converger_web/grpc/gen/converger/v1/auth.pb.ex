defmodule Converger.V1.Auth do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Auth",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :token, 1, type: :string
end
