defmodule Converger.V1.ReplayTruncated do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.ReplayTruncated",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :watermark, 1, type: :uint64
  field :head_seq, 2, type: :uint64, json_name: "headSeq"
end
