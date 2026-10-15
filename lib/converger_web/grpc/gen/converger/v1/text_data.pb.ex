defmodule Converger.V1.TextData do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.TextData",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :text, 1, type: :string
  field :attachments, 2, repeated: true, type: Google.Protobuf.Struct
end
