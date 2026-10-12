defmodule Converger.Channels.Broker.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Converger.Activities.Activity
  alias Converger.Activities.Serializer
  alias Converger.Channels.Broker.Envelope

  @tenant_id "11111111-1111-1111-1111-111111111111"
  @channel %{id: "22222222-2222-2222-2222-222222222222", tenant_id: @tenant_id}

  describe "outbound" do
    test "is the canonical activity plus channel_id and event" do
      activity = %Activity{
        id: Ecto.UUID.generate(),
        tenant_id: @tenant_id,
        conversation_id: Ecto.UUID.generate(),
        type: "message",
        sender: "agent-7",
        text: "Hi",
        seq: 3,
        metadata: %{"k" => "v"},
        inserted_at: ~U[2026-10-12 09:00:00.000000Z]
      }

      decoded = activity |> Envelope.encode(@channel) |> Jason.decode!()
      canonical = activity |> Serializer.canonical() |> Jason.encode!() |> Jason.decode!()

      assert Map.drop(decoded, ["channel_id", "event"]) == canonical
      assert decoded["channel_id"] == @channel.id
      assert decoded["tenant_id"] == @tenant_id
      assert decoded["conversation_id"] == activity.conversation_id
      assert decoded["event"] == "activity.created"
    end
  end

  describe "inbound" do
    test "takes the client fields, sender, participant and ids" do
      conversation_id = Ecto.UUID.generate()

      payload =
        Jason.encode!(%{
          "type" => "message",
          "text" => "hello",
          "attachments" => [],
          "metadata" => %{"crm" => 1},
          "sender" => "crm-bot",
          "conversation_id" => conversation_id,
          "tenant_id" => @tenant_id,
          "channel_id" => @channel.id,
          "idempotency_key" => "crm-42",
          "participant" => %{"external_id" => "cust-1", "display_name" => "Ada"},
          # server-controlled canonical fields are ignored
          "id" => Ecto.UUID.generate(),
          "seq" => 9,
          "inserted_at" => "2020-01-01T00:00:00Z"
        })

      assert {:ok, envelope} = Envelope.decode(payload, @channel)
      assert envelope.conversation_id == conversation_id
      assert envelope.idempotency_key == "crm-42"

      assert envelope.message == %{
               "type" => "message",
               "text" => "hello",
               "attachments" => [],
               "metadata" => %{"crm" => 1},
               "reply_to_id" => nil,
               "sender" => "crm-bot",
               "participant" => %{"external_id" => "cust-1", "display_name" => "Ada"}
             }
    end

    test "defaults: type message, sender from the participant, else external" do
      assert {:ok, %{message: %{"type" => "message", "sender" => "external"}}} =
               Envelope.decode(~s({"text": "x"}), @channel)

      assert {:ok, %{message: %{"sender" => "cust-1"}, conversation_id: nil}} =
               Envelope.decode(
                 ~s({"text": "x", "participant": {"external_id": "cust-1"}}),
                 @channel
               )
    end

    test "rejects what can never be accepted" do
      for {payload, reason} <- [
            {"nope", "message body is not valid JSON"},
            {"42", "message body is not a JSON object"},
            {~s({"text": 1}), "text must be a string"},
            {~s({"text": "x", "type": 1}), "type must be a string"},
            {~s({"text": "x", "attachments": {}}), "attachments must be a list"},
            {~s({"text": "x", "metadata": []}), "metadata must be an object"},
            {~s({"text": "x", "sender": ""}), "sender must be a non-empty string"},
            {~s({"attachments": []}), "message has neither text nor attachments"},
            {~s({"text": "x", "conversation_id": 5}), "conversation_id is not a UUID"},
            {~s({"text": "x", "participant": {"name": "x"}}),
             "participant must be an object with an external_id string"},
            {~s({"text": "x", "tenant_id": "other"}),
             "tenant_id does not match the consuming channel"},
            {~s({"text": "x", "channel_id": "other"}),
             "channel_id does not match the consuming channel"}
          ] do
        assert Envelope.decode(payload, @channel) == {:error, reason}, payload
      end
    end

    test "events without text are accepted" do
      assert {:ok, %{message: %{"type" => "event", "text" => nil}}} =
               Envelope.decode(~s({"type": "event", "metadata": {"name": "x"}}), @channel)
    end
  end
end
