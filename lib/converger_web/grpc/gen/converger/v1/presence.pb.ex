defmodule Converger.V1.Presence do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Presence",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :participant, 1, type: Converger.V1.Sender
  field :status, 2, type: :string
  field :connections, 3, proto3_optional: true, type: :uint32
  field :last_seen_at, 4, proto3_optional: true, type: :int64, json_name: "lastSeenAt"
end
