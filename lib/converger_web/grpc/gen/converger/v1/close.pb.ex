defmodule Converger.V1.Close do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Close",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :code, 1, type: :uint32
  field :reason, 2, type: :string
  field :retry_after_ms, 3, proto3_optional: true, type: :uint64, json_name: "retryAfterMs"
end
