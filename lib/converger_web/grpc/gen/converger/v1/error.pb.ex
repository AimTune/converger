defmodule Converger.V1.Error do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Error",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :code, 1, type: :string
  field :message, 2, type: :string
  field :number, 3, proto3_optional: true, type: :uint32
  field :retryable, 4, proto3_optional: true, type: :bool
  field :retry_after_ms, 5, proto3_optional: true, type: :uint64, json_name: "retryAfterMs"
  field :client_id, 6, proto3_optional: true, type: :string, json_name: "clientId"
  field :frame_type, 7, proto3_optional: true, type: :string, json_name: "frameType"
  field :details, 8, type: Google.Protobuf.Struct
end
