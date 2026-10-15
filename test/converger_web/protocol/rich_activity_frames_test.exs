defmodule ConvergerWeb.Protocol.RichActivityFramesTest do
  use ExUnit.Case, async: true

  alias Converger.Activities.Activity
  alias Converger.ProtocolSchemas, as: Schemas
  alias ConvergerWeb.Protocol.Frames

  defp activity(attrs) do
    struct!(
      Activity,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          seq: 2,
          sender: "agent-1",
          text: "hi",
          attachments: [],
          metadata: %{},
          conversation_id: Ecto.UUID.generate(),
          tenant_id: Ecto.UUID.generate(),
          inserted_at: ~U[2026-10-10 10:00:00.000000Z]
        },
        attrs
      )
    )
  end

  defp server_root, do: Schemas.build!("server-frame.schema.json")

  test "a threaded reply is a text frame with replyTo" do
    original = Ecto.UUID.generate()
    frame = Frames.activity(activity(%{type: "message", reply_to_id: original}), "user-1")

    assert %{"type" => "text", "replyTo" => %{"id" => ^original}} = frame
    assert :ok == Schemas.validate(frame, server_root())
  end

  test "reactions, edits and deletes are event frames naming the referenced activity" do
    original = Ecto.UUID.generate()

    reaction =
      Frames.activity(
        activity(%{type: "messageReaction", text: "👍", reply_to_id: original}),
        "user-1"
      )

    assert %{
             "type" => "event",
             "data" => %{
               "name" => "messageReaction",
               "text" => "agent-1 reacted with 👍",
               "value" => %{"replyToId" => ^original, "text" => "👍"}
             }
           } = reaction

    delete =
      Frames.activity(
        activity(%{type: "messageDelete", text: nil, reply_to_id: original}),
        "user-1"
      )

    assert %{"type" => "event", "data" => %{"name" => "messageDelete", "value" => value}} =
             delete

    assert value == %{"replyToId" => original}

    for frame <- [reaction, delete],
        do: assert(:ok == Schemas.validate(frame, server_root()))
  end
end
