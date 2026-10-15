defmodule Converger.V1.ChannelStream.Service do
  @moduledoc false

  use GRPC.Service, name: "converger.v1.ChannelStream", protoc_gen_elixir_version: "0.17.1"

  rpc(:Connect, stream(Converger.V1.ClientFrame), stream(Converger.V1.ServerFrame))
end

defmodule Converger.V1.ChannelStream.Stub do
  @moduledoc false

  use GRPC.Stub, service: Converger.V1.ChannelStream.Service
end
