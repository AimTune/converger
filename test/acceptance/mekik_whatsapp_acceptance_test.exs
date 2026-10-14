defmodule Converger.Acceptance.MekikWhatsAppAcceptanceTest do
  @moduledoc """
  Acceptance test of #64, Mode A: a WhatsApp (`whatsapp_meta`) channel with a
  routing rule to a `mekik` channel served by the fake mekik/1 server running
  the refund script (`Converger.FakeMekikServer`).

  Everything goes through the public edges: signed Meta webhooks posted to
  `/api/v1/channels/:id/inbound`, the Graph API answered by a `Req.Test`
  stub, the mekik server dialled over a real WebSocket. The scenario:

    1. the end user writes `ORD-42` on WhatsApp; mekik receives the user turn;
    2. mekik runs a tool (`tool_call` running, completed) and asks for
       approval (`interrupt` with Approve / Reject actions); WhatsApp gets an
       interactive reply-buttons message, and no tool trace;
    3. the user taps Approve; mekik receives `resume {answers: {int-1: value}}`;
    4. mekik resolves the interrupt and answers; WhatsApp gets the final text.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.{Activities, Channels, Repo, RoutingRules}
  alias Converger.Activities.Activity
  alias Converger.Channels.{InboundSignature, RichContent}
  alias Converger.Channels.Mekik.{Connections, Relay}
  alias Converger.Conversations.Conversation
  alias Converger.FakeMekikServer

  @app_secret "meta-app-secret-acceptance"
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

    {:ok, fake} = FakeMekikServer.start_link(self())
    on_exit(fn -> FakeMekikServer.stop(fake) end)

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

    mekik = channel_fixture(tenant, type: "mekik", config: %{"url" => fake.url})

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "whatsapp to mekik",
        tenant_id: tenant.id,
        source_channel_id: whatsapp.id,
        target_channel_ids: [mekik.id]
      })

    :ok = Relay.watch(mekik.id)
    on_exit(fn -> Connections.stop_channel(mekik.id) end)

    %{tenant: tenant, whatsapp: whatsapp, mekik: mekik, fake: fake}
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

  # The next client frame of `type` the fake mekik server received.
  defp upstream(type) do
    receive do
      {:mekik_frame, _socket, %{"type" => ^type} = frame} -> frame
      {:mekik_frame, _socket, _other} -> upstream(type)
    after
      5_000 -> flunk("mekik received no #{type}")
    end
  end

  # The next Graph API message send, as `{path, body, wamid}`. Typing indicators
  # (`status: read` + `typing_indicator`, forwarded while mekik runs) are
  # skipped.
  defp graph_send do
    assert_receive {:graph_api, path, body, wamid}, 5_000
    if signal?(body), do: graph_send(), else: {path, body, wamid}
  end

  # No further Graph API message send (signals aside).
  defp refute_graph_send(timeout \\ 300) do
    receive do
      {:graph_api, _path, body, _wamid} ->
        if signal?(body),
          do: refute_graph_send(timeout),
          else: flunk("unexpected Graph API send: #{inspect(body)}")
    after
      timeout -> :ok
    end
  end

  defp signal?(body), do: body["status"] == "read"

  defp stored(conversation_id), do: Activities.list_activities_since(conversation_id, nil)

  defp eventually(fun, attempts \\ 100) do
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

  test "a WhatsApp user is answered by mekik; the approval interrupt is WhatsApp buttons and the tap resumes the graph",
       ctx do
    # 1. The user's message reaches mekik as a text turn.
    turn =
      inbound!(ctx.whatsapp, %{
        "id" => "wamid.in-1",
        "type" => "text",
        "text" => %{"body" => "ORD-42"}
      })

    assert_receive {:mekik_connected, _socket, hello}, 5_000
    assert hello["userId"] == Repo.get!(Conversation, turn.conversation_id).participant_id

    text = upstream("text")
    assert text["data"] == %{"text" => "ORD-42"}
    assert text["meta"]["conversationId"] == turn.conversation_id
    assert text["meta"]["channel"] == %{"id" => ctx.whatsapp.id, "type" => "whatsapp_meta"}

    # 2. The interrupt reaches WhatsApp as interactive reply buttons, and it is
    # the first (and only) thing WhatsApp gets: the tool traces stay behind.
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

    interrupt =
      Enum.find(stored(turn.conversation_id), &(&1.message_type == "interrupt"))

    assert interrupt.payload["id"] == "int-1"

    assert approve == %{
             "type" => "reply",
             "reply" => %{"id" => RichContent.ref(interrupt.id, 0), "title" => "Approve"}
           }

    assert reject == %{
             "type" => "reply",
             "reply" => %{"id" => RichContent.ref(interrupt.id, 1), "title" => "Reject"}
           }

    refute_graph_send()

    assert Enum.count(stored(turn.conversation_id), &(&1.message_type == "tool_call")) == 2
    assert Activities.interrupt_open?(turn.conversation_id, "int-1")

    # 3. The tap answers the interrupt: mekik is resumed with the action's value.
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

    assert upstream("resume") == %{
             "type" => "resume",
             "answers" => %{"int-1" => %{"approved" => true}}
           }

    # 4. The graph finishes; WhatsApp gets the final text.
    {_path, reply, _wamid} = graph_send()

    assert %{"type" => "text", "to" => @phone, "text" => %{"body" => "Refund complete: ORD-42"}} =
             reply

    refute_graph_send()

    eventually(fn ->
      Enum.any?(stored(turn.conversation_id), &(&1.message_type == "interrupt_resolved"))
    end)

    refute Activities.interrupt_open?(turn.conversation_id, "int-1")

    assert stored(turn.conversation_id) |> Enum.map(&(&1.message_type || &1.text)) ==
             [
               "ORD-42",
               "tool_call",
               "tool_call",
               "interrupt",
               "Approve",
               "interrupt_resolved",
               "text"
             ]
  end

  test "a typed numeric reply on WhatsApp answers the interrupt too", ctx do
    turn =
      inbound!(ctx.whatsapp, %{
        "id" => "wamid.in-1",
        "type" => "text",
        "text" => %{"body" => "ORD-42"}
      })

    {_path, %{"type" => "interactive"}, _wamid} = graph_send()

    # "2" picks the second numbered action (Reject) of the open interrupt.
    reply =
      inbound!(ctx.whatsapp, %{
        "id" => "wamid.in-2",
        "type" => "text",
        "text" => %{"body" => "2"}
      })

    assert reply.text == "Reject"
    assert reply.metadata["action"]["source"] == "numeric"

    assert upstream("resume") == %{
             "type" => "resume",
             "answers" => %{"int-1" => %{"approved" => false}}
           }

    {_path, final, _wamid} = graph_send()
    assert final["text"] == %{"body" => "Refund declined."}
    refute_graph_send()
    assert reply.conversation_id == turn.conversation_id
  end
end
