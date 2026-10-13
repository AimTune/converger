defmodule Converger.V1.TypingSignal do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.TypingSignal",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :is_typing, 1, type: :bool, json_name: "isTyping"
end
