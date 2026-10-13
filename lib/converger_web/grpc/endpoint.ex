defmodule ConvergerWeb.GRPC.Endpoint do
  @moduledoc """
  The gRPC endpoint (ADR-0056): serves `converger.v1.ChannelStream`
  (`ConvergerWeb.GRPC.ChannelStreamServer`) on its own port. Started by
  `ConvergerWeb.GRPC.child_specs/0` when `GRPC_ENABLED=true`.
  """

  use GRPC.Endpoint

  run(ConvergerWeb.GRPC.ChannelStreamServer)
end
