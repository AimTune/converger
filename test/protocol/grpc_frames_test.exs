defmodule Converger.ProtocolGRPCFramesTest do
  @moduledoc """
  Conformance of the gRPC transport's frames (ADR-0056): every Protocol v1
  frame of the schema examples and the example sessions round-trips through
  protobuf (`ConvergerWeb.GRPC.Frames`, encoded to and decoded from the wire
  format) back to the same JSON frame, and the frame types the server emits
  map to their typed protobuf messages rather than `raw`.
  """

  use ExUnit.Case, async: true

  alias Converger.ProtocolSchemas, as: Schemas
  alias Converger.V1.{ClientFrame, ServerFrame}
  alias ConvergerWeb.GRPC.Frames

  @moduletag :protocol

  # Server frame types with a typed protobuf message; `text`, `event`,
  # `conversationUpdate` and message types are all `activity`.
  @typed_server %{
    "welcome" => :welcome,
    "ack" => :ack,
    "error" => :error,
    "deliveryStatus" => :delivery_status,
    "typing" => :typing,
    "presence" => :presence,
    "heartbeat" => :heartbeat,
    "tokenRefreshed" => :token_refreshed,
    "replayTruncated" => :replay_truncated,
    "text" => :activity,
    "event" => :activity,
    "conversationUpdate" => :activity
  }

  @typed_client %{
    "hello" => :hello,
    "text" => :message,
    "typing" => :typing,
    "read" => :read,
    "sync" => :sync,
    "ping" => :ping,
    "auth" => :auth
  }

  defp examples(direction) do
    schema_examples =
      for path <- Schemas.schema_paths(),
          String.starts_with?(path, "frames/#{direction}/"),
          example <- Schemas.read!(path)["examples"] || [],
          do: example

    session_examples =
      for path <- Path.wildcard(Path.join(Schemas.dir(), "examples/session-*.json")),
          %{"direction" => dir, "frame" => frame} <-
            path |> File.read!() |> Jason.decode!() |> Map.fetch!("frames"),
          dir == if(direction == "server", do: "s2c", else: "c2s"),
          # Channel-scoped envelopes have no type (section 10, planned).
          Map.has_key?(frame, "type"),
          do: frame

    schema_examples ++ session_examples
  end

  defp wire(%ServerFrame{} = frame), do: frame |> ServerFrame.encode() |> ServerFrame.decode()
  defp wire(%ClientFrame{} = frame), do: frame |> ClientFrame.encode() |> ClientFrame.decode()

  test "every server frame example round-trips through protobuf" do
    frames = examples("server")
    assert length(frames) > 20

    for frame <- frames do
      proto = frame |> Frames.to_server_frame() |> wire()
      assert Frames.from_server_frame(proto) == frame, inspect(frame)

      case @typed_server[frame["type"]] do
        nil -> :ok
        kind -> assert {^kind, _} = proto.frame, "#{frame["type"]} not typed: #{inspect(frame)}"
      end
    end
  end

  test "every client frame example round-trips through protobuf" do
    frames = examples("client")
    assert length(frames) > 10

    for frame <- frames do
      proto = frame |> Frames.to_client_frame() |> wire()
      assert Frames.from_client_frame(proto) == frame, inspect(frame)

      case @typed_client[frame["type"]] do
        nil -> :ok
        kind -> assert {^kind, _} = proto.frame, "#{frame["type"]} not typed: #{inspect(frame)}"
      end
    end
  end

  test "the frames the server builds map to typed messages" do
    frames = [
      ConvergerWeb.Protocol.Frames.heartbeat(12, "n-1"),
      ConvergerWeb.Protocol.Frames.replay_truncated(10, 20),
      ConvergerWeb.Protocol.Frames.token_refreshed(1_750_000_000_000),
      ConvergerWeb.Protocol.Frames.error("rate_limited", "slow down",
        retry_after_ms: 1500,
        client_id: "c-1",
        frame_type: "text",
        details: %{"text" => ["is too long"]}
      ),
      ConvergerWeb.ConvergerFrames.typing(true, %{id: "agent-1", role: "agent"}),
      ConvergerWeb.ConvergerFrames.presence(%{id: "bob", role: "user"}, 2, DateTime.utc_now())
    ]

    for frame <- frames do
      proto = frame |> Frames.to_server_frame() |> wire()
      refute match?({:raw, _}, proto.frame), inspect(frame)
      assert Frames.from_server_frame(proto) == Frames.stringify(frame)
    end
  end

  test "frames with fields the protobuf messages do not name travel as raw, losslessly" do
    frame = %{
      "type" => "ack",
      "clientId" => "c-1",
      "id" => "a",
      "seq" => 1,
      "timestamp" => 2,
      "x" => 1
    }

    proto = frame |> Frames.to_server_frame() |> wire()
    assert {:raw, _} = proto.frame
    assert Frames.from_server_frame(proto) == frame

    future = %{"type" => "interrupt", "seq" => 3, "data" => %{"id" => "i1", "kind" => "approval"}}
    proto = future |> Frames.to_server_frame() |> wire()
    assert Frames.from_server_frame(proto) == future
  end

  test "Struct numbers come back as integers when whole" do
    frame = %{
      "type" => "text",
      "clientId" => "c-1",
      "data" => %{"text" => "hi"},
      "metadata" => %{"n" => 3, "f" => 1.5}
    }

    proto = frame |> Frames.to_client_frame() |> wire()
    assert %{"metadata" => %{"n" => n, "f" => 1.5}} = Frames.from_client_frame(proto)
    assert n === 3
  end
end
