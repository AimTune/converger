defmodule Converger.ProtocolConformanceTest do
  @moduledoc """
  Conformance skeleton for Converger Protocol v1 (docs/protocol/v1.md).

  Today this pins the *contract*: the JSON Schemas build, every example in
  the schemas, the example sessions and the docs validates, known-bad frames
  are rejected, and mekik/1's golden fixtures are valid Converger frames.
  Server round-trips (connect, replay, ack) are added here by the
  implementation issues (#22-#28).
  """

  use ExUnit.Case, async: true

  alias Converger.ProtocolSchemas, as: Schemas

  @moduletag :protocol

  @docs_dir Path.expand("../../docs/protocol", __DIR__)
  @mekik_dir Path.expand("fixtures/mekik", __DIR__)

  # mekik/1 PERSISTENT_FRAME_TYPES (PROTOCOL.md section 2); rich message
  # frames are the open extension.
  @mekik_persistent ~w(text tool_call skill genui interrupt interrupt_resolved)
  @mekik_transient ~w(welcome genui_components skills run error)

  setup_all do
    roots = %{
      "s2c" => Schemas.build!("server-frame.schema.json"),
      "c2s" => Schemas.build!("client-frame.schema.json"),
      "s2c-envelope" => Schemas.build!("frames/channel/server-envelope.schema.json"),
      "c2s-envelope" => Schemas.build!("frames/channel/client-envelope.schema.json")
    }

    {:ok, roots: roots}
  end

  describe "schemas" do
    test "every schema builds and has a matching $id" do
      paths = Schemas.schema_paths()
      assert length(paths) > 40

      for path <- paths do
        schema = Schemas.read!(path)
        assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema", path
        assert schema["$id"] == Schemas.base_uri() <> path, path
        assert %JSV.Root{} = Schemas.build!(path)
      end
    end

    test "every frame and message schema has examples, and they validate" do
      for path <- Schemas.schema_paths(), path != "common.schema.json", not dispatcher?(path) do
        examples = Schemas.read!(path)["examples"] || []
        assert examples != [], "#{path} has no examples"
        root = Schemas.build!(path)

        for example <- examples do
          assert :ok == Schemas.validate(example, root), "#{path}: #{inspect(example)}"
        end
      end
    end

    test "frame examples also validate through the direction dispatchers", %{roots: roots} do
      for path <- Schemas.schema_paths(), String.starts_with?(path, "frames/") do
        direction =
          case path do
            "frames/server/" <> _ -> "s2c"
            "frames/client/" <> _ -> "c2s"
            "frames/channel/server" <> _ -> "s2c-envelope"
            "frames/channel/client" <> _ -> "c2s-envelope"
          end

        for example <- Schemas.read!(path)["examples"] do
          assert :ok == Schemas.validate(example, roots[direction]),
                 "#{path}: #{inspect(example)}"
        end
      end
    end
  end

  describe "example sessions" do
    test "every frame of every example session is valid", %{roots: roots} do
      sessions =
        Schemas.dir()
        |> Path.join("examples/session-*.json")
        |> Path.wildcard()

      assert length(sessions) >= 3

      for file <- sessions, %{"direction" => direction, "frame" => frame} <- frames(file) do
        assert :ok == Schemas.validate(frame, Map.fetch!(roots, direction)),
               "#{Path.basename(file)}: #{inspect(frame)}"
      end
    end

    test "persistent frames of a session have strictly increasing seq" do
      for file <- Path.wildcard(Path.join(Schemas.dir(), "examples/session-*.json")) do
        seqs =
          file
          |> frames()
          |> Enum.filter(&String.starts_with?(&1["direction"], "s2c"))
          # unwrap channel envelopes
          |> Enum.map(&Map.get(&1["frame"], "frame", &1["frame"]))
          |> Enum.map(& &1["seq"])
          |> Enum.filter(&is_integer/1)

        assert seqs == Enum.sort(seqs) and seqs == Enum.uniq(seqs), Path.basename(file)
      end
    end

    test "known-bad frames are rejected", %{roots: roots} do
      file = Path.join(Schemas.dir(), "examples/invalid.json")

      for %{"direction" => direction, "frame" => frame, "reason" => reason} <- frames(file) do
        assert {:error, _} = Schemas.validate(frame, Map.fetch!(roots, direction)), reason
      end
    end
  end

  describe "docs" do
    test "every annotated JSON example in docs/protocol validates" do
      blocks =
        for file <- Path.wildcard(Path.join(@docs_dir, "*.md")),
            [_, schema, json] <-
              Regex.scan(~r/^```json schema=(\S+)\r?\n(.*?)^```/ms, File.read!(file)),
            do: {Path.basename(file), schema, json}

      assert length(blocks) >= 20

      for {file, schema, json} <- blocks do
        frame =
          case Jason.decode(json) do
            {:ok, frame} -> frame
            {:error, error} -> flunk("#{file}: invalid JSON for #{schema}: #{inspect(error)}")
          end

        assert :ok == Schemas.validate(frame, Schemas.build!(schema)), "#{file}: #{json}"
      end
    end
  end

  describe "mekik/1 golden fixtures (test/protocol/fixtures/mekik)" do
    test "every expected frame is a valid Converger server frame", %{roots: roots} do
      fixtures = Path.wildcard(Path.join(@mekik_dir, "*.json"))
      assert length(fixtures) >= 8

      for file <- fixtures, frame <- expected_frames(file) do
        assert :ok == Schemas.validate(frame, roots["s2c"]),
               "#{Path.basename(file)}: #{inspect(frame)}"
      end
    end

    test "persistent frames carry a contiguous seq after startSeq; transient ones none" do
      for file <- Path.wildcard(Path.join(@mekik_dir, "*.json")) do
        fixture = file |> File.read!() |> Jason.decode!()
        frames = fixture["expectedFrames"]

        {persistent, transient} = Enum.split_with(frames, &Map.has_key?(&1, "seq"))

        expected_seqs =
          Enum.to_list((fixture["startSeq"] + 1)..(fixture["startSeq"] + length(persistent))//1)

        assert Enum.map(persistent, & &1["seq"]) == expected_seqs, Path.basename(file)

        for frame <- transient, do: assert(frame["type"] in @mekik_transient, inspect(frame))

        for frame <- persistent do
          assert frame["type"] in @mekik_persistent or rich_message?(frame), inspect(frame)
        end
      end
    end
  end

  defp frames(file), do: file |> File.read!() |> Jason.decode!() |> Map.fetch!("frames")

  defp expected_frames(file),
    do: file |> File.read!() |> Jason.decode!() |> Map.fetch!("expectedFrames")

  defp dispatcher?(path), do: path in ["server-frame.schema.json", "client-frame.schema.json"]

  # A rich message frame: the text envelope under a renderer name (mekik/1 section 4.5).
  defp rich_message?(frame),
    do: Enum.all?(~w(id seq from data timestamp), &Map.has_key?(frame, &1))
end
