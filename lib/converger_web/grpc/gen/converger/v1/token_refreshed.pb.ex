defmodule Converger.V1.TokenRefreshed do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.TokenRefreshed",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :expires_at, 1, type: :int64, json_name: "expiresAt"
end
