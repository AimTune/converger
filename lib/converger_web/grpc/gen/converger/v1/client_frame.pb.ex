defmodule Converger.V1.ClientFrame do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.ClientFrame",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:frame, 0)

  field :hello, 1, type: Converger.V1.Hello, oneof: 0
  field :message, 2, type: Converger.V1.MessageSend, oneof: 0
  field :typing, 3, type: Converger.V1.TypingSignal, oneof: 0
  field :read, 4, type: Converger.V1.Read, oneof: 0
  field :sync, 5, type: Converger.V1.Sync, oneof: 0
  field :ping, 6, type: Converger.V1.Ping, oneof: 0
  field :auth, 7, type: Converger.V1.Auth, oneof: 0
  field :raw, 15, type: Google.Protobuf.Struct, oneof: 0
end
