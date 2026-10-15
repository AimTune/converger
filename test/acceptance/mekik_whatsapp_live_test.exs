defmodule Converger.Acceptance.MekikWhatsAppLiveTest do
  @moduledoc """
  Live acceptance test of #64, Mode A, against a REAL mekik server: the stock
  refund demo of the mekik repository (`node examples/refund.ts --serve`, on
  port 8800), configured as a `mekik` channel and reached from WhatsApp
  through a routing rule.

      cd mekik/ts && pnpm install && pnpm build && node examples/refund.ts --serve
      MEKIK_URL=ws://127.0.0.1:8800/ws mix test --only mekik

  Excluded by default (tag `:mekik`, like
  `Converger.Channels.MekikLiveTest`): it needs the mekik repository and a
  running server. `Converger.Acceptance.MekikWhatsAppAcceptanceTest` plays the
  same scenario against the fake mekik/1 server and runs in CI.

  The WhatsApp side is the public edge, as in that test: signed Meta webhooks
  posted to `/api/v1/channels/:id/inbound`, the Graph API answered by a
  `Req.Test` stub. The scenario:

    1. the end user writes `ORD-42` on WhatsApp; the real refund graph looks
       the order up (`get_order` tool trace, an `order-card` GenUI card) and
       pauses on its approval `interrupt` (Approve / Reject actions);
    2. WhatsApp gets the interrupt as interactive reply buttons whose ids are
       Converger's answer keys; no tool trace and no GenUI card reaches it;
    3. the user taps Approve (a signed `button_reply` webhook); the graph
       resumes (`interrupt_resolved`, the `refund_payment` tool trace);
    4. WhatsApp gets the final text `Refund complete: ORD-42`.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.{Activities, Channels, Repo, RoutingRules}
  alias Converger.Activities.Activity
  alias Converger.Channels.{InboundSignature, RichContent}
  alias Converger.Channels.Mekik.{Connections, Relay}

  @moduletag :mekik

  @app_secret "meta-app-secret-live"
  @phone_number_id "106540352242922"
  @phone "16505551234"

  setup context do
    Req.Test.set_req_test_to_shared(context)

    webhook = Application.get_env(:converger, :webhook, [])
    whatsapp = Application.get_env(:converger, :whatsapp_req_options)

    Application.put_env(:converger, :webhook, Keyword.put(webhook, :allow_private_targets, true))

    Application.put_env(:converger, :whatsapp_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn ->
      Application.put_env(:converger, :webhook, webhook)

      if whatsapp,
        do: Application.put_env(:converger, :whatsapp_req_options, whatsapp),
        else: Application.delete_env(:converger, :whatsapp_req_options)
    end)

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      wamid = "wamid.out-#{System.unique_integer([:positive])}"
      send(test_pid, {:graph_api, conn.request_path, Jason.decode!(body), wamid})
      Req.Test.json(conn, %{"messages" => [%{"id" => wamid}]})
    end)

    tenant = tenant_fixture()

    {:ok, whatsapp} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "whatsapp_meta",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "phone_number_id" => @phone_number_id,
          "access_token" => "token",
          "verify_token" => "verify",
          "app_secret" => @app_secret
        }
      })

    url = System.get_env("MEKIK_URL", "ws://127.0.0.1:8800/ws")
    mekik = channel_fixture(tenant, type: "mekik", config: %{"url" => url})

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "whatsapp to mekik",
        tenant_id: tenant.id,
        source_channel_id: whatsapp.id,
        target_channel_ids: [mekik.id]
      })

    :ok = Relay.watch(mekik.id)
    on_exit(fn -> Connections.stop_channel(mekik.id) end)

    %{tenant: tenant, whatsapp: whatsapp, mekik: mekik}
  end

  # A signed Meta webhook carrying one user message.
  defp inbound!(whatsapp, message) do
    params = %{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "id" => "1",
          "changes" => [
            %{
              "field" => "messages",
              "value" => %{
                "messaging_product" => "whatsapp",
                "metadata" => %{"phone_number_id" => @phone_number_id},
                "contacts" => [%{"profile" => %{"name" => "Sheena"}, "wa_id" => @phone}],
                "messages" => [
                  Map.merge(%{"from" => @phone, "timestamp" => "1760140830"}, message)
                ]
              }
            }
          ]
        }
      ]
    }

    body = Jason.encode!(params)
    signature = "sha256=" <> InboundSignature.hmac_hex(@app_secret, body)

    [activity_id] =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(~p"/api/v1/channels/#{whatsapp.id}/inbound", body)
      |> json_response(200)
      |> Map.fetch!("activity_ids")

    Repo.get!(Activity, activity_id)
  end

  # The next Graph API message send, as `{path, body, wamid}`; typing
  # indicators (`status: read`) are skipped.
  defp graph_send do
    assert_receive {:graph_api, path, body, wamid}, 10_000
    if signal?(body), do: graph_send(), else: {path, body, wamid}
  end

  # Every Graph API message send (signals aside) within `ms`.
  defp graph_sends(ms) do
    receive do
      {:graph_api, _path, body, _wamid} ->
        if signal?(body), do: graph_sends(ms), else: [body | graph_sends(ms)]
    after
      ms -> []
    end
  end

  defp signal?(body), do: body["status"] == "read"

  defp stored(conversation_id), do: Activities.list_activities_since(conversation_id, nil)

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(50)
        eventually(fun, attempts - 1)
    end
  end

  test "a WhatsApp user is answered by the real refund graph; the approval is WhatsApp buttons and the tap resumes it",
       ctx do
    # 1. The user's order number reaches the real graph.
    turn =
      inbound!(ctx.whatsapp, %{
        "id" => "wamid.in-1",
        "type" => "text",
        "text" => %{"body" => "ORD-42"}
      })

    # 2. WhatsApp gets the demo's greeting (the graph's first bot text on a
    # new conversation), then the approval interrupt as interactive reply
    # buttons. The get_order traces and the order-card GenUI card are stored
    # but never sent.
    {_path, greeting, _wamid} = graph_send()

    assert %{
             "type" => "text",
             "to" => @phone,
             "text" => %{"body" => "Hi! Send an order number" <> _}
           } =
             greeting

    {path, interrupt_body, interrupt_wamid} = graph_send()
    assert path =~ "/#{@phone_number_id}/messages"

    assert %{
             "messaging_product" => "whatsapp",
             "to" => @phone,
             "type" => "interactive",
             "interactive" => %{
               "type" => "button",
               "body" => %{"text" => "Refund $249.9 for ORD-42?"},
               "action" => %{"buttons" => [approve, reject]}
             }
           } = interrupt_body

    activities = stored(turn.conversation_id)
    interrupt = Enum.find(activities, &(&1.message_type == "interrupt"))
    interrupt_id = interrupt.payload["id"]

    assert [
             %{"label" => "Approve", "value" => %{"approved" => true}},
             %{"label" => "Reject", "value" => %{"approved" => false}}
           ] = interrupt.payload["data"]["actions"]

    # The button ids are Converger's answer keys for the interrupt's actions.
    assert approve == %{
             "type" => "reply",
             "reply" => %{"id" => RichContent.ref(interrupt.id, 0), "title" => "Approve"}
           }

    assert reject == %{
             "type" => "reply",
             "reply" => %{"id" => RichContent.ref(interrupt.id, 1), "title" => "Reject"}
           }

    assert [%{"name" => "get_order"}, %{"name" => "get_order"}] = tool_calls(activities)
    assert Enum.any?(activities, &(&1.message_type == "genui"))
    assert Activities.interrupt_open?(turn.conversation_id, interrupt_id)
    assert graph_sends(500) == []

    # 3. The tap answers the interrupt; the real graph resumes.
    tap =
      inbound!(ctx.whatsapp, %{
        "id" => "wamid.in-2",
        "type" => "interactive",
        "context" => %{"from" => @phone_number_id, "id" => interrupt_wamid},
        "interactive" => %{
          "type" => "button_reply",
          "button_reply" => %{"id" => approve["reply"]["id"], "title" => "Approve"}
        }
      })

    assert tap.conversation_id == turn.conversation_id
    assert tap.reply_to_id == interrupt.id

    assert tap.metadata["action"] == %{
             "label" => "Approve",
             "value" => %{"approved" => true},
             "source" => "button"
           }

    # 4. WhatsApp gets the resumed run's text: the streamed token (a GenUI
    # text stream, one message when done, ADR-0064) and the consolidated
    # reply (a separate bubble in mekik/1, PROTOCOL.md 4.3). The
    # refund_payment traces are not sent.
    {_path, streamed, _wamid} = graph_send()
    assert %{"type" => "text", "text" => %{"body" => "Refund processed ✅"}} = streamed

    {_path, reply, _wamid} = graph_send()

    assert %{"type" => "text", "to" => @phone, "text" => %{"body" => "Refund complete: ORD-42"}} =
             reply

    assert graph_sends(800) == []

    eventually(fn ->
      Enum.any?(stored(turn.conversation_id), &(&1.message_type == "interrupt_resolved"))
    end)

    refute Activities.interrupt_open?(turn.conversation_id, interrupt_id)

    # Converger's transcript: the graph resumed after the tap, and its own
    # seq space is contiguous.
    activities = stored(turn.conversation_id)
    resolved = Enum.find(activities, &(&1.message_type == "interrupt_resolved"))
    assert resolved.payload["id"] == interrupt_id

    after_tap = Enum.drop_while(activities, &(&1.id != tap.id))
    assert [%{"name" => "refund_payment"}, %{"name" => "refund_payment"}] = tool_calls(after_tap)

    assert Enum.map(activities, & &1.seq) == Enum.to_list(1..length(activities))

    assert Enum.map(activities, &(&1.message_type || &1.text)) == [
             "ORD-42",
             "text",
             "tool_call",
             "tool_call",
             "genui",
             "interrupt",
             "Approve",
             "interrupt_resolved",
             "tool_call",
             "tool_call",
             "genui",
             "genui",
             "text"
           ]

    # 5. A second refund in the same conversation. The graph names its pause
    # by node (`approve:interrupt#0`), so the new interrupt reuses the id of
    # the resolved one; its buttons must still resume the graph.
    inbound!(ctx.whatsapp, %{
      "id" => "wamid.in-3",
      "type" => "text",
      "text" => %{"body" => "ORD-42"}
    })

    {_path, %{"type" => "interactive", "interactive" => %{"action" => action}}, wamid} =
      graph_send()

    second =
      stored(turn.conversation_id)
      |> Enum.filter(&(&1.message_type == "interrupt"))
      |> List.last()

    assert second.id != interrupt.id
    assert second.payload["id"] == interrupt_id
    assert Activities.interrupt_open?(turn.conversation_id, interrupt_id)
    assert [%{"reply" => %{"id" => approve_again}} | _] = action["buttons"]
    assert approve_again == RichContent.ref(second.id, 0)

    # A stale tap on the first message's button answers nothing...
    stale =
      inbound!(ctx.whatsapp, %{
        "id" => "wamid.in-4",
        "type" => "interactive",
        "context" => %{"from" => @phone_number_id, "id" => interrupt_wamid},
        "interactive" => %{
          "type" => "button_reply",
          "button_reply" => %{"id" => approve["reply"]["id"], "title" => "Approve"}
        }
      })

    assert stale.reply_to_id == interrupt.id

    # ...mekik refuses it as a new turn while parked (a transient error, not
    # sent to WhatsApp), and the second interrupt stays open.
    assert graph_sends(800) == []
    assert Activities.interrupt_open?(turn.conversation_id, interrupt_id)

    inbound!(ctx.whatsapp, %{
      "id" => "wamid.in-5",
      "type" => "interactive",
      "context" => %{"from" => @phone_number_id, "id" => wamid},
      "interactive" => %{
        "type" => "button_reply",
        "button_reply" => %{"id" => approve_again, "title" => "Approve"}
      }
    })

    {_path, %{"text" => %{"body" => "Refund processed ✅"}}, _wamid} = graph_send()
    {_path, %{"text" => %{"body" => "Refund complete: ORD-42"}}, _wamid} = graph_send()
    assert graph_sends(800) == []

    eventually(fn -> not Activities.interrupt_open?(turn.conversation_id, interrupt_id) end)
  end

  defp tool_calls(activities) do
    for %{message_type: "tool_call", payload: %{"data" => data}} <- activities, do: data
  end
end
