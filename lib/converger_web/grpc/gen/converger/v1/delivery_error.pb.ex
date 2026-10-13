defmodule Converger.V1.DeliveryError do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.DeliveryError",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :code, 1, type: :string
  field :message, 2, proto3_optional: true, type: :string
  field :retryable, 3, proto3_optional: true, type: :bool
end
