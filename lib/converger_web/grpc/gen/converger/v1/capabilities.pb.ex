defmodule Converger.V1.Capabilities do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Capabilities",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :acks, 1, proto3_optional: true, type: :bool
  field :receipts, 2, proto3_optional: true, type: :bool
  field :presence, 3, proto3_optional: true, type: :bool
  field :typing, 4, proto3_optional: true, type: :bool
  field :regenerate, 5, proto3_optional: true, type: :bool
  field :edit, 6, proto3_optional: true, type: :bool
  field :message_types, 7, repeated: true, type: :string, json_name: "messageTypes"
end
