defmodule Converger.Activities.TypedMessageTest do
  @moduledoc """
  Typed message payloads (#68, docs/protocol/messages.md section 4):
  splitting frames, validation against the Protocol v1 schemas, the text
  fallback, storage and the per-channel downgrade.
  """

  use Converger.DataCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Activities
  alias Converger.Activities.{Activity, Downgrade, MessagePayload}
  alias Converger.Channels.Adapter

  describe "MessagePayload.from_frame/2" do
    test "a plain text turn stays in the plain columns" do
      assert :plain == MessagePayload.from_frame(%{"type" => "text", "data" => %{"text" => "hi"}})

      assert :plain ==
               MessagePayload.from_frame(%{
                 "type" => "text",
                 "id" => "c-1",
                 "clientId" => "c-1",
                 "data" => %{"text" => "hi", "attachments" => []},
                 "metadata" => %{"a" => 1}
               })
    end

    test "text with actions, a kept id or extra data fields is typed" do
      frame = %{
        "type" => "text",
        "data" => %{"text" => "Track it?"},
        "actions" => [%{"label" => "Track"}]
      }

      assert {:ok, "text", %{"data" => %{"text" => "Track it?"}, "actions" => [_]}} =
               MessagePayload.from_frame(frame)

      bot = %{"type" => "text", "id" => "msg-1", "seq" => 3, "data" => %{"text" => "hi"}}

      assert {:ok, "text", %{"id" => "msg-1", "data" => %{"text" => "hi"}}} =
               MessagePayload.from_frame(bot, keep_id: true)

      assert {:ok, "text", %{"data" => %{"text" => "hi", "urls" => []}}} =
               MessagePayload.from_frame(%{
                 "type" => "text",
                 "data" => %{"text" => "hi", "urls" => []}
               })
    end

    test "message frames drop the server envelope; native frames keep every field" do
      card = %{
        "type" => "card",
        "id" => "card-1",
        "seq" => 7,
        "from" => "bot",
        "timestamp" => 1,
        "sender" => %{"id" => "x", "role" => "bot"},
        "clientId" => "c-1",
        "metadata" => %{},
        "replyTo" => %{"id" => "y"},
        "meta" => %{"locale" => "tr"},
        "data" => %{"title" => "T"},
        "x-extra" => true
      }

      assert {:ok, "card", %{"data" => %{"title" => "T"}, "x-extra" => true}} =
               MessagePayload.from_frame(card)

      interrupt = %{
        "type" => "interrupt",
        "seq" => 7,
        "id" => "i#0",
        "data" => %{"payload" => %{}}
      }

      assert {:ok, "interrupt", %{"id" => "i#0", "data" => %{"payload" => %{}}}} =
               MessagePayload.from_frame(interrupt)
    end
  end

  describe "MessagePayload.validate/2" do
    test "vocabulary types are validated against their schema" do
      assert :ok == MessagePayload.validate("image", %{"data" => %{"src" => "https://x.test/a"}})

      assert {:error, %{"#/data" => [message]}} =
               MessagePayload.validate("image", %{"data" => %{"alt" => "x"}})

      assert message =~ "src"
    end

    test "native types are validated against their frame schema" do
      tool = %{"data" => %{"id" => "t1", "name" => "get_order", "status" => "running"}}
      assert :ok == MessagePayload.validate("tool_call", tool)
      assert {:error, _} = MessagePayload.validate("tool_call", %{"data" => %{"id" => "t1"}})
    end

    test "open renderer names need an object data; reserved names are refused" do
      assert :ok == MessagePayload.validate("order-summary", %{"data" => %{"total" => 1}})
      assert {:error, _} = MessagePayload.validate("order-summary", %{"data" => "x"})
      assert {:error, %{"#/type" => _}} = MessagePayload.validate("run", %{"data" => %{}})
      assert {:error, _} = MessagePayload.validate("Not A Type", %{"data" => %{}})
    end
  end

  describe "MessagePayload.fallback_text/2" do
    test "renders each type as plain text" do
      cases = [
        {"text", %{"data" => %{"text" => "hi"}}, "hi"},
        {"text", %{"data" => %{"text" => ""}, "actions" => [%{"label" => "A"}]}, "A"},
        {"buttons", %{"data" => %{"buttons" => [%{"label" => "A"}, %{"label" => "B"}]}}, "A | B"},
        {"quick-reply", %{"data" => %{"text" => "Helpful?", "actions" => []}}, "Helpful?"},
        {"card", %{"data" => %{"title" => "ORD-1", "subtitle" => "$5"}}, "ORD-1\n$5"},
        {"carousel", %{"data" => %{"cards" => [%{"title" => "A"}, %{"title" => "B"}]}}, "A\n\nB"},
        {"image", %{"data" => %{"src" => "s", "caption" => "Receipt"}}, "Receipt"},
        {"file", %{"data" => %{"url" => "u", "name" => "a.pdf"}}, "a.pdf"},
        {"location", %{"data" => %{"latitude" => 1.5, "longitude" => 2}}, "1.5, 2"},
        {"contact", %{"data" => %{"name" => "Desk"}}, "Desk"},
        {"interrupt", %{"id" => "i", "data" => %{"payload" => %{"title" => "Refund?"}}},
         "Refund?"},
        {"order-summary", %{"data" => %{"text" => "Order 42"}}, "Order 42"},
        {"tool_call", %{"data" => %{"id" => "t", "name" => "n", "status" => "running"}}, nil},
        {"genui", %{"streamId" => "s", "done" => true, "chunk" => %{}}, nil},
        {"order-summary", %{"data" => %{}}, nil}
      ]

      for {type, payload, expected} <- cases do
        assert MessagePayload.fallback_text(type, payload) == expected, type
      end
    end
  end

  describe "storage" do
    setup do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel)
      %{tenant: tenant, conversation: conversation}
    end

    defp create(ctx, attrs) do
      %{
        "tenant_id" => ctx.tenant.id,
        "conversation_id" => ctx.conversation.id,
        "sender" => "bot-1",
        "type" => "message"
      }
      |> Map.merge(attrs)
      |> Activities.create_activity()
    end

    test "a typed message is stored with its fallback text", ctx do
      payload = %{"data" => %{"title" => "ORD-1", "buttons" => [%{"label" => "Track"}]}}

      assert {:ok, %Activity{} = activity} =
               create(ctx, %{"message_type" => "card", "payload" => payload})

      activity = Repo.reload!(activity)
      assert activity.message_type == "card"
      assert activity.payload == payload
      assert activity.text == "ORD-1"
    end

    test "an explicit text wins over the fallback", ctx do
      payload = %{"data" => %{"title" => "ORD-1"}}

      assert {:ok, activity} =
               create(ctx, %{"message_type" => "card", "payload" => payload, "text" => "custom"})

      assert activity.text == "custom"
    end

    test "invalid payloads are rejected per field", ctx do
      assert {:error, changeset} =
               create(ctx, %{
                 "message_type" => "buttons",
                 "payload" => %{"data" => %{"buttons" => [%{"value" => 1}]}}
               })

      assert %{payload: [message]} = errors_on(changeset)
      assert message =~ "data/buttons/0"
    end

    test "message_type and payload come together and only on messages", ctx do
      assert %{message_type: ["is required with payload"]} =
               ctx |> create(%{"payload" => %{"data" => %{}}}) |> errors()

      assert %{payload: ["is required with message_type"]} =
               ctx |> create(%{"message_type" => "card"}) |> errors()

      assert %{message_type: ["is only allowed on message activities"]} =
               ctx
               |> create(%{
                 "type" => "event",
                 "message_type" => "order-summary",
                 "payload" => %{"data" => %{}}
               })
               |> errors()
    end

    test "payloads above max_payload_bytes are rejected", ctx do
      text = String.duplicate("a", Activity.limits()[:max_payload_bytes])

      assert %{payload: [message]} =
               ctx
               |> create(%{
                 "message_type" => "order-summary",
                 "payload" => %{"data" => %{"t" => text}}
               })
               |> errors()

      assert message =~ "max is"
    end

    test "unknown renderer types are stored and counted", ctx do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "unknown-type-#{inspect(ref)}",
        [:converger, :activities, :unknown_type],
        fn _event, measurements, metadata, _ -> send(test_pid, {ref, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("unknown-type-#{inspect(ref)}") end)

      assert {:ok, _} =
               create(ctx, %{"message_type" => "order-summary", "payload" => %{"data" => %{}}})

      assert_receive {^ref, %{count: 1}, %{message_type: "order-summary"}}

      assert {:ok, _} = create(ctx, %{"message_type" => "card", "payload" => card()})
      refute_receive {^ref, _, _}
    end

    defp errors(result) do
      assert {:error, %Ecto.Changeset{} = changeset} = result
      errors_on(changeset)
    end

    test "an interrupt id reused by a later run is open again until resolved again (#64)",
         ctx do
      interrupt = fn ->
        {:ok, activity} =
          create(ctx, %{
            "message_type" => "interrupt",
            "payload" => %{
              "id" => "approve:interrupt#0",
              "data" => %{"payload" => %{"title" => "Refund?"}}
            }
          })

        activity
      end

      resolve = fn ->
        {:ok, _} =
          create(ctx, %{
            "message_type" => "interrupt_resolved",
            "payload" => %{"id" => "approve:interrupt#0", "data" => %{}}
          })
      end

      id = "approve:interrupt#0"
      first = interrupt.()
      assert Activities.interrupt_open?(ctx.conversation.id, id)
      assert Activities.interrupt_open?(first)

      resolve.()
      refute Activities.interrupt_open?(ctx.conversation.id, id)
      refute Activities.interrupt_open?(first)

      # The graph's next run pauses on the same node: same id, open again.
      second = interrupt.()
      assert Activities.interrupt_open?(ctx.conversation.id, id)
      assert Activities.interrupt_open?(second)
      refute Activities.interrupt_open?(first)

      # A reply to the open one resumes the graph; a reply to the stale one
      # is a plain turn.
      reply = fn to, value ->
        ConvergerWeb.Protocol.BotRelay.turn_frame(
          %{
            "type" => "text",
            "from" => "user",
            "data" => %{"text" => "Approve"},
            "replyTo" => %{"id" => to.id},
            "metadata" => %{"action" => %{"label" => "Approve", "value" => value}}
          },
          ctx.conversation.id
        )
      end

      assert reply.(second, %{"approved" => true}) == %{
               "type" => "resume",
               "answers" => %{id => %{"approved" => true}}
             }

      assert %{"type" => "text"} = reply.(first, %{"approved" => true})

      resolve.()
      refute Activities.interrupt_open?(ctx.conversation.id, id)
      refute Activities.interrupt_open?(second)
      assert Activities.open_interrupts(ctx.conversation.id) == []
    end
  end

  describe "downgrade" do
    setup do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      %{tenant: tenant, conversation: conversation_fixture(tenant, channel)}
    end

    defp typed(message_type, payload, text) do
      %Activity{
        type: "message",
        sender: "bot-1",
        text: text,
        attachments: [],
        message_type: message_type,
        payload: payload
      }
    end

    test "adapters that forward the canonical activity get every type natively" do
      assert Adapter.message_types("webhook") == :all
      assert Adapter.message_types("websocket") == :all
      assert Adapter.message_types("sms_vonage") == []
      assert "buttons" in Adapter.message_types("whatsapp_meta")

      assert :native == Downgrade.plan(typed("card", card(), "ORD-1"), %{type: "webhook"})
    end

    test "declared types are native; media arrive as legacy attachments" do
      channel = %{type: "telegram", config: %{}}
      assert :native == Downgrade.plan(typed("card", card(), "ORD-1"), channel)

      image =
        typed("image", %{"data" => %{"src" => "https://x.test/a.png", "caption" => "R"}}, "R")

      assert {:downgrade,
              %Activity{
                text: "R",
                message_type: nil,
                attachments: [
                  %{"contentType" => "image/png", "contentUrl" => "https://x.test/a.png"}
                ]
              }} = Downgrade.plan(image, channel)

      location = typed("location", %{"data" => %{"latitude" => 1, "longitude" => 2}}, "1, 2")

      assert {:downgrade,
              %Activity{
                text: nil,
                attachments: [%{"contentType" => "application/vnd.converger.location"}]
              }} = Downgrade.plan(location, channel)
    end

    test "other end-user channels get the numbered text rendering" do
      channel = %{type: "sms_vonage", config: %{}}

      assert {:downgrade,
              %Activity{type: "message", text: "ORD-1\n1. Track", message_type: nil, payload: nil}} =
               Downgrade.plan(typed("card", card(), "ORD-1"), channel)

      image = typed("image", %{"data" => %{"src" => "https://x.test/a.png"}}, nil)

      assert {:downgrade, %Activity{text: "https://x.test/a.png", attachments: []}} =
               Downgrade.plan(image, channel)

      assert :skip == Downgrade.plan(typed("genui", %{"chunk" => %{}}, nil), channel)

      # Chat adapters without native buttons: numbered text, media as files.
      for type <- ~w(messenger instagram viber discord teams sms_twilio) do
        assert {:downgrade, %Activity{text: "ORD-1\n1. Track"}} =
                 Downgrade.plan(typed("card", card(), "ORD-1"), %{type: type})
      end

      assert {:downgrade, %Activity{attachments: [%{"contentUrl" => "https://x.test/a.png"}]}} =
               Downgrade.plan(image, %{type: "messenger"})
    end

    test "interrupts for a tool or an event are skipped" do
      channel = %{type: "whatsapp_meta", config: %{}}
      tool = typed("interrupt", %{"data" => %{"payload" => %{}, "tool" => %{"name" => "x"}}}, nil)
      assert :skip == Downgrade.plan(tool, channel)

      ask =
        typed(
          "interrupt",
          %{"data" => %{"payload" => %{"title" => "OK?"}, "actions" => [%{"label" => "Yes"}]}},
          "OK?"
        )

      assert :native == Downgrade.plan(ask, channel)

      assert {:downgrade, %Activity{text: "OK?\n1. Yes"}} =
               Downgrade.plan(ask, %{type: "sms_vonage"})
    end

    test "a GenUI stream reaches end-user channels as its joined text when done", ctx do
      channel = %{type: "telegram", config: %{}}

      chunk = fn chunk, done ->
        %{"streamId" => "s-1", "done" => done, "chunk" => chunk}
      end

      for payload <- [
            chunk.(%{"type" => "ui", "component" => "order-card", "id" => 1}, false),
            chunk.(%{"type" => "text", "content" => "Process", "id" => 2}, false),
            chunk.(%{"type" => "text", "content" => "Processing done", "id" => 2}, false),
            chunk.(%{"type" => "text", "content" => "Anything else?", "id" => 3}, false)
          ] do
        {:ok, activity} = create(ctx, %{"message_type" => "genui", "payload" => payload})
        assert :skip == Downgrade.plan(activity, channel)
      end

      {:ok, done} =
        create(ctx, %{
          "message_type" => "genui",
          "payload" => chunk.(%{"type" => "event", "name" => "stream_done", "id" => 4}, true)
        })

      assert {:downgrade, %Activity{text: "Processing done\n\nAnything else?", message_type: nil}} =
               Downgrade.plan(done, channel)

      assert :native == Downgrade.plan(done, %{type: "webhook"})
    end

    test "tool traces reach end-user channels only with show_tool_traces" do
      tool = typed("tool_call", %{"data" => %{"name" => "get_order", "status" => "running"}}, nil)

      assert :skip == Downgrade.plan(tool, %{type: "telegram", config: %{}})

      assert {:downgrade, %Activity{text: "get_order: running"}} =
               Downgrade.plan(tool, %{type: "telegram", config: %{"show_tool_traces" => true}})
    end

    test "show_tool_traces must be a boolean" do
      tenant = tenant_fixture()

      assert {:error, changeset} =
               Converger.Channels.create_channel(%{
                 name: "c",
                 type: "webhook",
                 mode: "duplex",
                 status: "active",
                 tenant_id: tenant.id,
                 config: %{"url" => "https://example.com/hook", "show_tool_traces" => "yes"}
               })

      assert "show_tool_traces must be a boolean" in errors_on(changeset).config
    end
  end

  defp card, do: %{"data" => %{"title" => "ORD-1", "buttons" => [%{"label" => "Track"}]}}
end
