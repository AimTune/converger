defmodule Converger.MekikStorageRoundTripTest do
  @moduledoc """
  mekik/1 compatibility (#63, docs/protocol/v1.md section 14): every
  persistent frame of mekik's golden fixtures is stored as an activity, read
  back and rendered as a Protocol v1 frame, and compares equal to the
  received frame in canonical JSON (keys sorted, mekik/1 section 9).

  The server owns `seq` (renumbered into the conversation's seq space) and,
  on message frames, `timestamp` (its commit time) and `sender` (an additive
  Converger field), so those are set aside before the comparison;
  everything else, including a bot-supplied message `id`, is byte-identical.
  """

  use Converger.DataCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Activities
  alias Converger.Activities.MessagePayload
  alias Converger.ProtocolSchemas
  alias ConvergerWeb.Protocol.Frames

  @moduletag :protocol

  @mekik_dir Path.expand("fixtures/mekik", __DIR__)

  # Fields of a message frame that the server sets, not the sender.
  @server_owned ~w(seq timestamp sender)

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    %{tenant: tenant, channel: channel}
  end

  test "every persistent fixture frame round-trips through storage", ctx do
    fixtures = Path.wildcard(Path.join(@mekik_dir, "*.json"))
    assert length(fixtures) >= 8
    root = ProtocolSchemas.root!("server-frame.schema.json")

    frames =
      for file <- fixtures,
          frame <- file |> File.read!() |> Jason.decode!() |> Map.fetch!("expectedFrames"),
          Map.has_key?(frame, "seq"),
          do: {Path.basename(file), frame}

    assert length(frames) >= 20

    for {file, frame} <- frames do
      conversation = conversation_fixture(ctx.tenant, ctx.channel)
      activity = store!(conversation, frame)

      rendered =
        activity.id
        |> Activities.get_activity!()
        |> Frames.activity("end-user-1", false)

      assert :ok == ProtocolSchemas.validate(rendered, root), "#{file}: #{inspect(rendered)}"
      assert rendered["seq"] == activity.seq

      assert canonical_json(drop_server_owned(rendered)) ==
               canonical_json(drop_server_owned(frame)),
             "#{file}: #{inspect(frame)} came back as #{inspect(rendered)}"
    end
  end

  test "plain text frames keep the plain columns, typed ones the payload", ctx do
    conversation = conversation_fixture(ctx.tenant, ctx.channel)

    plain = store!(conversation, %{"type" => "text", "data" => %{"text" => "hi"}})
    assert plain.message_type == nil and plain.payload == nil and plain.text == "hi"

    tool = %{
      "type" => "tool_call",
      "seq" => 99,
      "data" => %{"id" => "t1", "name" => "get_order", "status" => "running"}
    }

    stored = store!(conversation, tool)
    assert stored.message_type == "tool_call"
    assert stored.payload == Map.drop(tool, ["type", "seq"])
    assert stored.text == nil
  end

  # A bot frame as the mekik relay (#64) and the agent socket (#67) will
  # store it: a bot names its messages, so the frame id is kept.
  defp store!(conversation, frame) do
    params =
      case MessagePayload.from_frame(frame, keep_id: true) do
        :plain -> %{"text" => frame["data"]["text"]}
        {:ok, type, payload} -> %{"message_type" => type, "payload" => payload}
      end

    {:ok, activity} =
      params
      |> Map.merge(%{
        "type" => "message",
        "sender" => "mekik-bot",
        "tenant_id" => conversation.tenant_id,
        "conversation_id" => conversation.id
      })
      |> Activities.create_activity()

    activity
  end

  defp drop_server_owned(frame), do: Map.drop(frame, @server_owned)

  # Canonical JSON: object keys sorted at every level (mekik/1 section 9).
  defp canonical_json(value), do: value |> canonical() |> Jason.encode!()

  defp canonical(%{} = map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {key, canonical(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
