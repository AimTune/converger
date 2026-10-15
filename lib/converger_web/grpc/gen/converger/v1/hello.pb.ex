defmodule Converger.V1.Hello do
  @moduledoc false

  use Protobuf,
    full_name: "converger.v1.Hello",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:position, 0)

  field :protocol, 1, proto3_optional: true, type: :string
  field :conversation_id, 2, proto3_optional: true, type: :string, json_name: "conversationId"
  field :user_id, 3, proto3_optional: true, type: :string, json_name: "userId"
  field :watermark, 4, type: :uint64, oneof: 0
  field :legacy_watermark, 5, type: :string, json_name: "legacyWatermark", oneof: 0
  field :token, 6, proto3_optional: true, type: :string
  field :meta, 7, type: Google.Protobuf.Struct
  field :watermarks, 8, repeated: true, type: Converger.V1.Hello.WatermarksEntry, map: true
  field :components_hash, 9, proto3_optional: true, type: :string, json_name: "componentsHash"
  field :tools, 10, repeated: true, type: Google.Protobuf.Struct
  field :skills_hash, 11, proto3_optional: true, type: :string, json_name: "skillsHash"
  field :skills, 12, repeated: true, type: Google.Protobuf.Struct
end
