defmodule ConvergerWeb.ConvergerChannelSendTest do
  @moduledoc """
  Converger Protocol v1 sends on the Phoenix binding: the `frame` event with
  client ids, `ack` and `error` frames, and the in-flight limit
  (docs/protocol/v1.md, sections 2.2 and 7; #24).
  """

  use ConvergerWeb.ChannelCase

  import Ecto.Query, only: [from: 2]
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias Converger.ConvergerAPI.Watermark
  alias Converger.{Conversations, ProtocolSchemas, Repo}
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  # Sends reply after the pipeline ran (inline deliveries); the first one of
  # a test runs cold.
  @timeout 1_000

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    {token, socket} = join!(channel, conversation)

    %{socket: socket, conversation: conversation, channel: channel, token: token}
  end

  defp join!(channel, conversation) do
    {:ok, token, _claims} =
      ConvergerToken.generate_conversation_token(channel, conversation.id, user_id: "alice")

    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:conversation:#{conversation.id}")

    {token, socket}
  end

  defp text(client_id, text \\ "hello") do
    %{"type" => "text", "clientId" => client_id, "data" => %{"text" => text}}
  end

  # Every frame is checked against the v1 server frame schema.
  defp assert_frame(type) do
    assert_push "frame", %{"type" => ^type} = frame, @timeout
    root = ProtocolSchemas.build!("server-frame.schema.json")
    assert :ok == ProtocolSchemas.validate(frame, root)
    frame
  end

  defp activities(conversation) do
    Repo.all(
      from(a in Activity,
        where: a.conversation_id == ^conversation.id and a.sender == "alice",
        order_by: a.seq
      )
    )
  end

  describe "send with a clientId" do
    test "persists the activity and acks with its id, seq and timestamp", %{
      socket: socket,
      conversation: conversation
    } do
      ref = push(socket, "frame", text("c-1", "Where is my order?"))

      ack = assert_frame("ack")
      assert_reply ref, :ok, %{}, @timeout

      assert [activity] = activities(conversation)
      assert activity.text == "Where is my order?"
      assert activity.type == "message"
      assert activity.idempotency_key == "ws:alice:c-1"

      assert ack == %{
               "type" => "ack",
               "clientId" => "c-1",
               "id" => activity.id,
               "seq" => activity.seq,
               "timestamp" => DateTime.to_unix(activity.inserted_at, :millisecond)
             }
    end

    test "the same clientId twice creates one activity and two identical acks", %{
      socket: socket,
      conversation: conversation
    } do
      push(socket, "frame", text("c-1"))
      first = assert_frame("ack")
      assert_push "activitySet", _, @timeout

      push(socket, "frame", text("c-1"))
      second = assert_frame("ack")

      assert [_one] = activities(conversation)
      assert Map.delete(second, "duplicate") == first
      assert second["duplicate"] == true
      refute Map.has_key?(first, "duplicate")

      # A duplicate is not fanned out again.
      refute_push "activitySet", _
    end

    test "a postActivity with the same clientId is the same send", %{
      socket: socket,
      conversation: conversation
    } do
      push(socket, "frame", text("c-1"))
      ack = assert_frame("ack")

      ref = push(socket, "postActivity", %{"text" => "hello", "clientId" => "c-1"})

      assert_reply ref, :ok, %{id: id, seq: seq, duplicate: true}, @timeout
      assert {id, seq} == {ack["id"], ack["seq"]}
      assert [_one] = activities(conversation)
    end

    test "the ack carries the seq that other clients see in activitySet", %{
      socket: socket,
      conversation: conversation,
      token: token
    } do
      test_pid = self()

      # Another connection of the conversation. Its transport is a separate
      # process, so its pushes are told apart from the sender's. It stays
      # alive until the test ends: its channel stops when it exits.
      forward = fn forward ->
        receive do
          %Phoenix.Socket.Message{event: "activitySet", payload: payload} ->
            send(test_pid, {:other_activity_set, payload})
            forward.(forward)
        end
      end

      other_transport = spawn_link(fn -> forward.(forward) end)
      {:ok, other} = connect(ConvergerSocket, %{"token" => token})

      {:ok, _, _} =
        join(
          %{other | transport_pid: other_transport},
          ConvergerChannel,
          "converger:conversation:#{conversation.id}"
        )

      push(socket, "frame", text("c-1"))
      ack = assert_frame("ack")

      assert_receive {:other_activity_set, %{activities: [activity], watermark: watermark}},
                     @timeout

      assert activity.id == ack["id"]
      assert {:ok, {:seq, seq}} = Watermark.decode(watermark)
      assert seq == ack["seq"]
    end

    test "the ack reaches the sender before its own activitySet", %{socket: socket} do
      push(socket, "frame", text("c-1"))

      assert_receive %Phoenix.Socket.Message{event: event}, @timeout
      assert event == "frame"
      assert_push "activitySet", _, @timeout
    end

    test "a mekik/1 id is used as the clientId", %{socket: socket, conversation: conversation} do
      push(socket, "frame", %{
        "type" => "text",
        "id" => "1750000000000-k3j2h1g",
        "timestamp" => 1_750_000_000_000,
        "data" => %{"text" => "hi"}
      })

      assert %{"clientId" => "1750000000000-k3j2h1g"} = assert_frame("ack")
      assert [%{idempotency_key: "ws:alice:1750000000000-k3j2h1g"}] = activities(conversation)
    end

    test "clientId wins over id", %{socket: socket} do
      push(socket, "frame", Map.put(text("c-1"), "id", "other-id"))
      assert %{"clientId" => "c-1"} = assert_frame("ack")
    end

    test "legacy attachments and metadata are stored", %{
      socket: socket,
      conversation: conversation
    } do
      attachment = %{"contentType" => "image/png", "contentUrl" => "https://example.test/a.png"}

      push(socket, "frame", %{
        "type" => "text",
        "clientId" => "c-1",
        "data" => %{"text" => "look", "attachments" => [attachment]},
        "metadata" => %{"locale" => "tr-TR"},
        "meta" => %{"ignored" => true}
      })

      assert_frame("ack")
      assert [activity] = activities(conversation)
      assert activity.attachments == [attachment]
      assert activity.metadata == %{"locale" => "tr-TR"}
    end

    test "on a non-websocket channel a resend is acked as a duplicate too" do
      tenant = tenant_fixture()
      channel = webhook_channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel)
      {_token, socket} = join!(channel, conversation)

      push(socket, "frame", text("c-1"))
      first = assert_frame("ack")
      push(socket, "frame", text("c-1"))
      assert Map.put(first, "duplicate", true) == assert_frame("ack")
      assert [_one] = activities(conversation)
    end
  end

  describe "send without a clientId" do
    test "is persisted once per frame and not acked", %{
      socket: socket,
      conversation: conversation
    } do
      frame = %{"type" => "text", "data" => %{"text" => "hi"}}
      ref = push(socket, "frame", frame)
      assert_reply ref, :ok, %{}, @timeout
      push(socket, "frame", frame)

      assert_push "activitySet", _, @timeout
      assert_push "activitySet", _, @timeout
      refute_push "frame", _
      assert length(activities(conversation)) == 2
    end

    test "an id that is not a valid clientId is ignored", %{
      socket: socket,
      conversation: conversation
    } do
      push(socket, "frame", %{"type" => "text", "id" => "has spaces", "data" => %{"text" => "hi"}})

      assert_push "activitySet", _, @timeout
      refute_push "frame", _
      assert [%{idempotency_key: nil}] = activities(conversation)
    end
  end

  describe "rejected sends" do
    test "an invalid clientId is a bad_request and nothing is stored", %{
      socket: socket,
      conversation: conversation
    } do
      push(socket, "frame", text(String.duplicate("a", 129)))

      assert %{"data" => %{"code" => "bad_request", "number" => 1000, "retryable" => false}} =
               error = assert_frame("error")

      refute Map.has_key?(error["data"], "clientId")
      assert activities(conversation) == []
    end

    test "a text frame without data.text is a bad_request", %{socket: socket} do
      push(socket, "frame", %{"type" => "text", "clientId" => "c-1", "data" => %{}})

      assert %{"data" => %{"code" => "bad_request", "clientId" => "c-1", "frameType" => "text"}} =
               assert_frame("error")
    end

    test "a closed conversation answers conversation_closed with the clientId", %{
      socket: socket,
      conversation: conversation
    } do
      {:ok, _} = Conversations.close_conversation(conversation)
      assert_push "activitySet", _, @timeout

      push(socket, "frame", text("c-1"))

      assert %{
               "data" => %{
                 "code" => "conversation_closed",
                 "number" => 4000,
                 "retryable" => false,
                 "clientId" => "c-1"
               }
             } = assert_frame("error")

      assert activities(conversation) == []
    end

    test "a send acked before the close still gets its original ack", %{
      socket: socket,
      conversation: conversation
    } do
      push(socket, "frame", text("c-1"))
      ack = assert_frame("ack")

      {:ok, _} = Conversations.close_conversation(conversation)
      push(socket, "frame", text("c-1"))

      assert Map.put(ack, "duplicate", true) == assert_frame("ack")
    end

    test "a validation failure is invalid_message with details per field", %{socket: socket} do
      max = Activity.limits()[:max_text_bytes]
      push(socket, "frame", text("c-1", String.duplicate("a", max + 1)))

      assert %{
               "data" => %{
                 "code" => "invalid_message",
                 "clientId" => "c-1",
                 "details" => %{text: [_]}
               }
             } = assert_frame("error")
    end

    test "the tenant rate limit answers rate_limited with retryAfterMs", %{socket: socket} do
      previous = Application.get_env(:converger, Converger.RateLimit, [])

      Application.put_env(
        :converger,
        Converger.RateLimit,
        Keyword.put(previous, :limits, %{activity_create: {1, 60_000}})
      )

      on_exit(fn -> Application.put_env(:converger, Converger.RateLimit, previous) end)

      push(socket, "frame", text("c-1"))
      assert_frame("ack")
      push(socket, "frame", text("c-2"))

      assert %{"data" => %{"code" => "rate_limited", "retryable" => true, "clientId" => "c-2"}} =
               error = assert_frame("error")

      assert is_integer(error["data"]["retryAfterMs"])
    end

    test "rich message types are not supported yet", %{socket: socket} do
      push(socket, "frame", %{
        "type" => "location",
        "clientId" => "c-1",
        "data" => %{"latitude" => 41.0, "longitude" => 29.0}
      })

      assert %{"data" => %{"code" => "invalid_message", "frameType" => "location"}} =
               assert_frame("error")
    end
  end

  describe "in-flight limit" do
    setup do
      previous = Application.get_env(:converger, :websocket)
      Application.put_env(:converger, :websocket, Keyword.put(previous, :max_in_flight, 3))
      on_exit(fn -> Application.put_env(:converger, :websocket, previous) end)
    end

    test "sends beyond max_in_flight are refused newest first and can be retried", %{
      socket: socket,
      conversation: conversation
    } do
      # Queue five sends while the channel is busy.
      :sys.suspend(socket.channel_pid)
      for n <- 1..5, do: push(socket, "frame", text("c-#{n}"))
      :sys.resume(socket.channel_pid)

      for n <- 1..3 do
        client_id = "c-#{n}"
        assert %{"clientId" => ^client_id} = assert_frame("ack")
      end

      for n <- 4..5 do
        client_id = "c-#{n}"

        assert %{
                 "data" => %{
                   "code" => "too_many_in_flight",
                   "retryable" => true,
                   "clientId" => ^client_id
                 }
               } = assert_frame("error")
      end

      assert length(activities(conversation)) == 3

      push(socket, "frame", text("c-4"))
      assert %{"clientId" => "c-4"} = assert_frame("ack")
      assert length(activities(conversation)) == 4
    end

    test "queued protocol frames do not count as sends", %{socket: socket} do
      :sys.suspend(socket.channel_pid)
      push(socket, "frame", text("c-1"))
      for _ <- 1..5, do: push(socket, "frame", %{"type" => "subscribe"})
      push(socket, "frame", text("c-2"))
      :sys.resume(socket.channel_pid)

      assert %{"clientId" => "c-1"} = assert_frame("ack")
      for _ <- 1..5, do: assert(%{"data" => %{"code" => "bad_request"}} = assert_frame("error"))
      assert %{"clientId" => "c-2"} = assert_frame("ack")
    end

    test "welcome limits announce the configured value" do
      assert ConvergerWeb.Protocol.limits()["maxInFlight"] == 3
    end
  end

  describe "other frames" do
    test "a protocol frame that is not a client frame here is a bad_request", %{
      socket: socket
    } do
      ref = push(socket, "frame", %{"type" => "subscribe"})
      assert_reply ref, :ok, %{}, @timeout

      assert %{"data" => %{"code" => "bad_request", "frameType" => "subscribe"}} =
               assert_frame("error")

      push(socket, "frame", text("c-1"))
      assert_frame("ack")
    end

    test "a frame that is not an object is a bad_request", %{socket: socket} do
      ref = push(socket, "frame", "nope")
      assert_reply ref, :ok, %{}, @timeout
      assert %{"data" => %{"code" => "bad_request"}} = assert_frame("error")
    end

    test "a frame on a channel topic is refused" do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)

      {:ok, token, _} = ConvergerToken.generate_token(channel, scope: "channel")
      {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

      {:ok, _, socket} =
        subscribe_and_join(socket, ConvergerChannel, "converger:channel:#{channel.id}")

      ref = push(socket, "frame", text("c-1"))
      assert_reply ref, :error, %{reason: "bad_request"}, @timeout
    end
  end
end
