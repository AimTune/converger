defmodule ConvergerWeb.ConvergerChannelSignalsTest do
  @moduledoc """
  Delivery/read receipts, typing indicators and presence on the Converger
  WebSocket channel (#25). Every pushed frame is validated against its
  Protocol v1 JSON Schema.

  All connections are joined from the test process, so every push of every
  connection arrives here; the tests rely on a connection never receiving
  its own typing, read and presence frames to tell them apart.
  """
  use ConvergerWeb.ChannelCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Deliveries, ProtocolSchemas, Receipts}
  alias Converger.Auth.ConvergerToken
  alias Converger.ConvergerAPI.Watermark
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp connect_as(channel, conversation, opts) do
    {:ok, token, _claims} =
      ConvergerToken.generate_conversation_token(channel, conversation.id, opts)

    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:conversation:#{conversation.id}")

    socket
  end

  defp activity(conversation, sender, text \\ "hello") do
    {:ok, activity} =
      Activities.create_activity(%{
        "tenant_id" => conversation.tenant_id,
        "conversation_id" => conversation.id,
        "sender" => sender,
        "text" => text
      })

    assert_push "activitySet", _, 1_000
    activity
  end

  defp wire(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp assert_valid(frame, schema) do
    root = ProtocolSchemas.build!("frames/server/#{schema}.schema.json")
    assert :ok == ProtocolSchemas.validate(wire(frame), root)
    wire(frame)
  end

  describe "deliveryStatus" do
    test "a WhatsApp DLR 'read' reaches the WS client", %{channel: channel, conversation: c} do
      _agent = connect_as(channel, c, user_id: "agent-7")
      activity = activity(c, "agent-7")

      delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)
      {:ok, _} = Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.out-1"})

      assert_push "deliveryStatus", sent, 1_000
      assert %{"data" => %{"status" => "sent"}} = assert_valid(sent, "deliveryStatus")

      # What InboundController does with a parsed WhatsApp status webhook.
      {:ok, _} =
        Deliveries.apply_status_update(channel.id, %{
          "provider_message_id" => "wamid.out-1",
          "status" => "read",
          "timestamp" => "1750000006"
        })

      assert_push "deliveryStatus", read, 1_000
      frame = assert_valid(read, "deliveryStatus")

      assert frame["data"] == %{
               "activityId" => activity.id,
               "seq" => activity.seq,
               "channelId" => channel.id,
               "status" => "read",
               "timestamp" => 1_750_000_006_000
             }
    end

    @tag :capture_log
    test "a dead-lettered delivery is pushed as failed with the error", %{
      channel: channel,
      conversation: c
    } do
      _agent = connect_as(channel, c, user_id: "agent-7")
      activity = activity(c, "agent-7")

      delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)
      {:ok, _} = Deliveries.mark_dead(delivery, "recipient blocked")

      assert_push "deliveryStatus", failed, 1_000
      frame = assert_valid(failed, "deliveryStatus")

      assert %{
               "status" => "failed",
               "attempt" => 1,
               "error" => %{"code" => "delivery_failed", "message" => "recipient blocked"}
             } = frame["data"]
    end

    test "an identified end user only sees the status of their own activities", %{
      channel: channel,
      conversation: c
    } do
      _user = connect_as(channel, c, user_id: "user-a")

      for {sender, visible?} <- [{"agent-7", false}, {"user-a", true}] do
        activity = activity(c, sender)
        delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)
        {:ok, _} = Deliveries.mark_sent(delivery)

        if visible? do
          assert_push "deliveryStatus", %{data: %{activityId: id}}, 1_000
          assert id == activity.id
        else
          refute_push "deliveryStatus", _
        end
      end
    end
  end

  describe "typing" do
    test "typing from client A is seen by client B within 100 ms", %{
      channel: channel,
      conversation: c
    } do
      a = connect_as(channel, c, user_id: "user-a")
      _b = connect_as(channel, c, user_id: "agent-7")

      ref = push(a, "typing", %{"isTyping" => true})
      assert_reply ref, :ok

      # assert_push waits 100 ms by default (ExUnit assert_receive_timeout).
      assert_push "typing", frame

      assert assert_valid(frame, "typing") == %{
               "type" => "typing",
               "isTyping" => true,
               "from" => "user",
               "sender" => %{"id" => "user-a", "role" => "user"}
             }

      push(a, "typing", %{"isTyping" => false})
      assert_push "typing", %{isTyping: false}
    end

    test "a connection does not receive its own typing frames", %{
      channel: channel,
      conversation: c
    } do
      a = connect_as(channel, c, user_id: "user-a")
      ref = push(a, "typing", %{"isTyping" => true})
      assert_reply ref, :ok
      refute_push "typing", _
    end

    test "repeats inside 2 s are dropped, a state change is not", %{
      channel: channel,
      conversation: c
    } do
      a = connect_as(channel, c, user_id: "user-a")
      _b = connect_as(channel, c, [])

      push(a, "typing", %{"isTyping" => true})
      push(a, "typing", %{"isTyping" => true})
      push(a, "typing", %{"isTyping" => false})

      assert_push "typing", %{isTyping: true}
      assert_push "typing", %{isTyping: false}
      refute_push "typing", _
    end

    test "closing a connection while typing clears the indicator", %{
      channel: channel,
      conversation: c
    } do
      a = connect_as(channel, c, user_id: "user-a")
      _b = connect_as(channel, c, [])

      push(a, "typing", %{"isTyping" => true})
      assert_push "typing", %{isTyping: true}

      Process.unlink(a.channel_pid)
      leave(a)

      assert_push "typing", %{isTyping: false, sender: %{id: "user-a"}}
    end

    test "a malformed typing frame is answered with bad_request", %{
      channel: channel,
      conversation: c
    } do
      a = connect_as(channel, c, user_id: "user-a")
      ref = push(a, "typing", %{"isTyping" => "yes"})
      assert_reply ref, :error, %{reason: "bad_request"}
    end
  end

  describe "read" do
    test "a read watermark is stored and sent to the other participants", %{
      channel: channel,
      conversation: c
    } do
      user = connect_as(channel, c, user_id: "user-a")
      _agent = connect_as(channel, c, user_id: "agent-7")
      first = activity(c, "agent-7", "one")
      assert_push "activitySet", _, 1_000
      second = activity(c, "agent-7", "two")
      assert_push "activitySet", _, 1_000

      ref = push(user, "read", %{"watermark" => second.seq})
      assert_reply ref, :ok, %{watermark: seq}, 1_000
      assert seq == second.seq

      assert_push "deliveryStatus", frame, 1_000
      data = assert_valid(frame, "deliveryStatus")["data"]
      assert data["upToSeq"] == second.seq
      assert data["status"] == "read"
      assert data["by"] == %{"id" => "user-a", "role" => "user"}
      refute_push "deliveryStatus", _

      assert Receipts.read_seq(c.id, "user-a") == second.seq

      # Never backwards, and no receipt for a watermark that does not advance.
      ref = push(user, "read", %{"watermark" => first.seq})
      assert_reply ref, :ok, %{watermark: ^seq}, 1_000
      refute_push "deliveryStatus", _
    end

    test "the opaque activitySet watermark and the decimal string form are accepted", %{
      channel: channel,
      conversation: c
    } do
      user = connect_as(channel, c, user_id: "user-a")
      first = activity(c, "agent-7", "one")
      second = activity(c, "agent-7", "two")

      ref = push(user, "read", %{"watermark" => Watermark.encode(first.seq)})
      assert_reply ref, :ok, %{watermark: seq}, 1_000
      assert seq == first.seq

      ref = push(user, "read", %{"watermark" => Integer.to_string(second.seq)})
      assert_reply ref, :ok, %{watermark: seq}, 1_000
      assert seq == second.seq
    end

    test "an invalid watermark is rejected", %{channel: channel, conversation: c} do
      user = connect_as(channel, c, user_id: "user-a")

      for watermark <- [0, -1, "abc", Watermark.encode(0), nil, %{}] do
        ref = push(user, "read", %{"watermark" => watermark})
        assert_reply ref, :error, %{reason: "invalid_watermark"}, 1_000
      end
    end
  end

  describe "presence" do
    test "participants see each other come online and go offline", %{
      channel: channel,
      conversation: c
    } do
      _user = connect_as(channel, c, user_id: "user-a")
      agent = connect_as(channel, c, user_id: "agent-7")

      # The user is told the agent came online, the agent gets the snapshot.
      assert_push "presence", %{data: %{participant: %{id: "agent-7"}}} = online, 500

      assert assert_valid(online, "presence")["data"] == %{
               "participant" => %{"id" => "agent-7", "role" => "user"},
               "status" => "online",
               "connections" => 1
             }

      assert_push "presence", %{
        data: %{participant: %{id: "user-a", role: "user"}, status: "online"}
      }

      Process.unlink(agent.channel_pid)
      leave(agent)

      assert_push "presence",
                  %{data: %{participant: %{id: "agent-7"}, status: "offline"}} =
                    offline,
                  500

      assert %{"connections" => 0, "lastSeenAt" => _} = assert_valid(offline, "presence")["data"]
    end

    test "anonymous end users are not announced by default", %{channel: channel, conversation: c} do
      _anonymous = connect_as(channel, c, [])
      _agent = connect_as(channel, c, user_id: "agent-7")

      refute_push "presence", _, 300
    end

    test "presence can be turned off per channel", %{tenant: tenant} do
      channel = channel_fixture(tenant, %{config: %{"presence" => "off"}})
      c = conversation_fixture(tenant, channel)

      _user = connect_as(channel, c, user_id: "user-a")
      _agent = connect_as(channel, c, user_id: "agent-7")

      refute_push "presence", _, 300
    end

    test "\"all\" announces anonymous end users too", %{tenant: tenant} do
      channel = channel_fixture(tenant, %{config: %{"presence" => "all"}})
      c = conversation_fixture(tenant, channel)

      _anonymous = connect_as(channel, c, [])
      _agent = connect_as(channel, c, user_id: "agent-7")

      assert_push "presence", %{data: %{participant: %{id: "anonymous"}, status: "online"}}, 500
    end
  end
end
