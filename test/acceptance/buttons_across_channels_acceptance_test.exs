defmodule Converger.Acceptance.ButtonsAcrossChannelsAcceptanceTest do
  @moduledoc """
  Acceptance test of #68: an agent sends ONE `buttons` message, and each
  channel renders it natively (docs/protocol/messages.md section 5); the
  user's answers come back to the agent in one shape (section 6).

  The agent is a channel-scoped native socket on a `websocket` bot channel
  (`ConvergerWeb.ProtocolClient`, every server frame validated against the
  v1 schemas). Routing rules send four end-user channels to it:

    * web widget: a `websocket` channel, the end user on a native socket;
    * WhatsApp (`whatsapp_meta`): signed Meta webhooks, Graph API stubbed;
    * Telegram: Bot API webhooks with the secret token, Bot API stubbed;
    * email (SMTP provider): rfc822 posts with basic auth, mail captured by
      `Swoosh.Adapters.Test`.

  On each channel the user writes first, the agent answers the conversation
  with the same `buttons` payload, the channel shows chips / interactive
  buttons / an inline keyboard / a numbered list, and the user picks the
  second option (a chip tap, a button reply, a `callback_query`, an email
  reply "2"). Each answer reaches the agent as a `text` frame whose
  `data.text` is the action's value, with `metadata.action {label, value,
  source}` and `replyTo.id` naming the agent's buttons activity.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Channels, Repo, RoutingRules}
  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias Converger.Channels.Adapters.Telegram
  alias Converger.Channels.{InboundSignature, RichContent}
  alias ConvergerWeb.ProtocolClient, as: Client

  @wa_secret "meta-app-secret-buttons"
  @wa_phone_number_id "106540352242922"
  @wa_phone "16505551234"

  @tg_token "7000000001:AAFakeTokenForTests"
  @tg_secret "tg_secret-token"
  @tg_chat 123_456_789

  @email_password "s3cret"

  @buttons %{
    "data" => %{
      "text" => "How can I help?",
      "buttons" => [
        %{"label" => "Track an order", "value" => "/track"},
        %{"label" => "Pricing", "value" => "/pricing"},
        %{"label" => "Talk to a human", "value" => "/human"}
      ]
    }
  }

  # What every channel's answer must look like at the agent (`source` aside).
  @answer %{"label" => "Pricing", "value" => "/pricing"}

  setup context do
    Req.Test.set_req_test_to_shared(context)
    test_pid = self()

    whatsapp_env = Application.get_env(:converger, :whatsapp_req_options)
    swoosh_shared = Application.get_env(:swoosh, :shared_test_process)

    Application.put_env(:converger, :whatsapp_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    # Mail is sent from socket and pipeline processes, not the test's callers.
    Application.put_env(:swoosh, :shared_test_process, test_pid)

    on_exit(fn ->
      if whatsapp_env,
        do: Application.put_env(:converger, :whatsapp_req_options, whatsapp_env),
        else: Application.delete_env(:converger, :whatsapp_req_options)

      if swoosh_shared,
        do: Application.put_env(:swoosh, :shared_test_process, swoosh_shared),
        else: Application.delete_env(:swoosh, :shared_test_process)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      wamid = "wamid.out-#{System.unique_integer([:positive])}"
      send(test_pid, {:graph_api, Jason.decode!(body), wamid})
      Req.Test.json(conn, %{"messages" => [%{"id" => wamid}]})
    end)

    Req.Test.stub(Telegram, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      method = conn.request_path |> String.split("/") |> List.last()
      params = if body == "", do: %{}, else: Jason.decode!(body)
      send(test_pid, {:telegram, method, params})

      result =
        if method == "sendMessage",
          do: %{"message_id" => 900, "chat" => %{"id" => @tg_chat}},
          else: true

      Req.Test.json(conn, %{"ok" => true, "result" => result})
    end)

    tenant = tenant_fixture()
    bot = channel_fixture(tenant)
    widget = channel_fixture(tenant)

    whatsapp =
      create_channel!(tenant, "whatsapp_meta", %{
        "phone_number_id" => @wa_phone_number_id,
        "access_token" => "token",
        "verify_token" => "verify",
        "app_secret" => @wa_secret
      })

    telegram =
      create_channel!(tenant, "telegram", %{
        "bot_token" => @tg_token,
        "secret_token" => @tg_secret
      })

    email =
      channel_fixture(tenant, %{
        type: "email",
        config: %{
          "from" => "ACME Support <support@acme.test>",
          "inbound_secret" => @email_password,
          "provider" => "smtp",
          "smtp_host" => "smtp.example.com"
        }
      })

    for source <- [widget, whatsapp, telegram, email] do
      {:ok, _rule} =
        RoutingRules.create_routing_rule(%{
          name: "#{source.type} to bot",
          tenant_id: tenant.id,
          source_channel_id: source.id,
          target_channel_ids: [bot.id]
        })
    end

    %{
      tenant: tenant,
      bot: bot,
      widget: widget,
      whatsapp: whatsapp,
      telegram: telegram,
      email: email,
      port: Client.start_server()
    }
  end

  defp create_channel!(tenant, type, config) do
    {:ok, channel} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: type,
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: config
      })

    channel
  end

  ## The agent

  defp open(port, token) do
    {:ok, client} = Client.connect(port, headers: [{"authorization", "Bearer #{token}"}])
    client = Client.push(client, %{"type" => "hello"})
    {%{"type" => "welcome"}, client} = Client.recv(client)
    client
  end

  defp agent(ctx) do
    {:ok, token, _} = ConvergerToken.generate_token(ctx.bot, scope: "channel", user_id: "agent-1")
    open(ctx.port, token)
  end

  # The next enveloped frame of `type` for `conversation_id` (others dropped).
  defp agent_recv(agent, conversation_id, type) do
    case Client.recv(agent, 5_000) do
      {%{"conversationId" => ^conversation_id, "frame" => %{"type" => ^type} = frame}, agent} ->
        {frame, agent}

      {%{}, agent} ->
        agent_recv(agent, conversation_id, type)

      {other, _agent} ->
        flunk("agent: expected #{type}, got #{inspect(other)}")
    end
  end

  # The agent answers a conversation with the buttons message; returns the
  # stored activity.
  defp send_buttons(agent, conversation_id) do
    client_id = "buttons-#{conversation_id}"

    frame =
      Map.merge(@buttons, %{"type" => "buttons", "clientId" => client_id})

    agent = Client.push(agent, %{"conversationId" => conversation_id, "frame" => frame})
    {%{"clientId" => ^client_id, "id" => id}, agent} = agent_recv(agent, conversation_id, "ack")

    activity = Repo.get!(Activity, id)
    assert activity.message_type == "buttons"
    assert activity.payload == @buttons
    {activity, agent}
  end

  # The normalised answer as the agent sees it.
  defp answer_shape(frame) do
    %{
      "text" => frame["data"]["text"],
      "action" => Map.delete(frame["metadata"]["action"], "source"),
      "replyTo" => frame["replyTo"]["id"]
    }
  end

  ## Channel edges

  defp wa_inbound!(whatsapp, message) do
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
                "metadata" => %{"phone_number_id" => @wa_phone_number_id},
                "contacts" => [%{"profile" => %{"name" => "Sheena"}, "wa_id" => @wa_phone}],
                "messages" => [
                  Map.merge(%{"from" => @wa_phone, "timestamp" => "1760140830"}, message)
                ]
              }
            }
          ]
        }
      ]
    }

    body = Jason.encode!(params)
    signature = "sha256=" <> InboundSignature.hmac_hex(@wa_secret, body)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", signature)
    |> post(~p"/api/v1/channels/#{whatsapp.id}/inbound", body)
    |> inbound_activity!()
  end

  # The next Graph API message send, as `{body, wamid}` (typing indicators skipped).
  defp graph_send do
    assert_receive {:graph_api, body, wamid}, 5_000
    if body["status"] == "read", do: graph_send(), else: {body, wamid}
  end

  defp tg_inbound!(telegram, update) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-telegram-bot-api-secret-token", @tg_secret)
    |> post(~p"/api/v1/channels/#{telegram.id}/inbound", Jason.encode!(update))
    |> inbound_activity!()
  end

  defp tg_user, do: %{"id" => @tg_chat, "is_bot" => false, "first_name" => "Ada"}
  defp tg_chat, do: %{"id" => @tg_chat, "first_name" => "Ada", "type" => "private"}

  # The next Telegram sendMessage (chat actions skipped).
  defp tg_send do
    assert_receive {:telegram, method, params}, 5_000
    if method == "sendMessage", do: params, else: tg_send()
  end

  defp email_inbound!(email, mime) do
    build_conn()
    |> put_req_header(
      "authorization",
      "Basic " <> Base.encode64("converger:" <> @email_password)
    )
    |> put_req_header("content-type", "message/rfc822")
    |> post(~p"/api/v1/channels/#{email.id}/inbound", mime)
    |> inbound_activity!()
  end

  defp mime(text, extra_headers) do
    Enum.join(
      [
        "From: Jane Doe <jane@example.com>",
        "To: support@acme.test",
        "Subject: Help",
        "Message-ID: <#{System.unique_integer([:positive])}@example.com>"
      ] ++ extra_headers ++ ["Content-Type: text/plain; charset=utf-8", "", text, ""],
      "\r\n"
    )
  end

  defp inbound_activity!(conn) do
    [id] = conn |> json_response(200) |> Map.fetch!("activity_ids")
    Repo.get!(Activity, id)
  end

  test "one buttons message renders natively on four channels; every answer reaches the agent in one shape",
       ctx do
    agent = agent(ctx)

    # --- Web widget: chips over the native socket ------------------------
    widget_conversation = conversation_fixture(ctx.tenant, ctx.widget)

    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(ctx.widget, widget_conversation.id,
        user_id: "alice"
      )

    user = open(ctx.port, token)
    user = Client.push(user, %{"type" => "text", "data" => %{"text" => "hi"}})
    {_turn, agent} = agent_recv(agent, widget_conversation.id, "text")

    {web_offer, agent} = send_buttons(agent, widget_conversation.id)

    {chips, user} = Client.recv_type(user, "buttons", 5_000)
    assert chips["from"] == "bot"
    assert chips["id"] == web_offer.id
    assert chips["data"] == @buttons["data"]

    _user =
      Client.push(user, %{
        "type" => "text",
        "data" => %{"text" => "/pricing"},
        "replyTo" => %{"id" => chips["id"], "seq" => chips["seq"]},
        "metadata" => %{
          "action" => %{"label" => "Pricing", "value" => "/pricing", "source" => "web"}
        }
      })

    {web_answer, agent} = agent_recv(agent, widget_conversation.id, "text")

    # --- WhatsApp: interactive reply buttons ------------------------------
    wa_turn =
      wa_inbound!(ctx.whatsapp, %{
        "id" => "wamid.in-1",
        "type" => "text",
        "text" => %{"body" => "hi"}
      })

    {_turn, agent} = agent_recv(agent, wa_turn.conversation_id, "text")
    {wa_offer, agent} = send_buttons(agent, wa_turn.conversation_id)

    {wa_message, wa_wamid} = graph_send()

    assert %{
             "to" => @wa_phone,
             "type" => "interactive",
             "interactive" => %{
               "type" => "button",
               "body" => %{"text" => "How can I help?"},
               "action" => %{"buttons" => wa_buttons}
             }
           } = wa_message

    assert wa_buttons ==
             for(
               {title, index} <- Enum.with_index(["Track an order", "Pricing", "Talk to a human"]),
               do: %{
                 "type" => "reply",
                 "reply" => %{"id" => RichContent.ref(wa_offer.id, index), "title" => title}
               }
             )

    wa_inbound!(ctx.whatsapp, %{
      "id" => "wamid.in-2",
      "type" => "interactive",
      "context" => %{"from" => @wa_phone_number_id, "id" => wa_wamid},
      "interactive" => %{
        "type" => "button_reply",
        "button_reply" => %{"id" => RichContent.ref(wa_offer.id, 1), "title" => "Pricing"}
      }
    })

    {wa_answer, agent} = agent_recv(agent, wa_turn.conversation_id, "text")

    # --- Telegram: inline keyboard ----------------------------------------
    tg_turn =
      tg_inbound!(ctx.telegram, %{
        "update_id" => 912_345_601,
        "message" => %{
          "message_id" => 41,
          "from" => tg_user(),
          "chat" => tg_chat(),
          "date" => 1_760_140_800,
          "text" => "hi"
        }
      })

    {_turn, agent} = agent_recv(agent, tg_turn.conversation_id, "text")
    {tg_offer, agent} = send_buttons(agent, tg_turn.conversation_id)

    keyboard_message = tg_send()
    assert keyboard_message["chat_id"] == to_string(@tg_chat)
    assert keyboard_message["text"] == "How can I help?"

    assert %{"inline_keyboard" => rows} = keyboard_message["reply_markup"]

    assert List.flatten(rows) ==
             for(
               {text, index} <- Enum.with_index(["Track an order", "Pricing", "Talk to a human"]),
               do: %{"text" => text, "callback_data" => RichContent.ref(tg_offer.id, index)}
             )

    tg_inbound!(ctx.telegram, %{
      "update_id" => 912_345_602,
      "callback_query" => %{
        "id" => "4382bfdwdsb323b2d9",
        "from" => tg_user(),
        "message" => %{
          "message_id" => 900,
          "chat" => tg_chat(),
          "date" => 1_760_140_830,
          "text" => "How can I help?",
          "reply_markup" => keyboard_message["reply_markup"]
        },
        "chat_instance" => "-8124960233891872543",
        "data" => RichContent.ref(tg_offer.id, 1)
      }
    })

    {tg_answer, agent} = agent_recv(agent, tg_turn.conversation_id, "text")

    # --- Email: a numbered list -------------------------------------------
    email_turn = email_inbound!(ctx.email, mime("Hello, I have a question.", []))
    {_turn, agent} = agent_recv(agent, email_turn.conversation_id, "text")
    {email_offer, agent} = send_buttons(agent, email_turn.conversation_id)

    assert_receive {:email, sent}, 5_000
    assert [{_name, "jane@example.com"}] = sent.to
    assert sent.text_body =~ "How can I help?"
    assert sent.text_body =~ "1. Track an order"
    assert sent.text_body =~ "2. Pricing"
    assert sent.text_body =~ "3. Talk to a human"

    "<" <> message_id = sent.headers["Message-ID"]
    message_id = String.trim_trailing(message_id, ">")

    email_inbound!(
      ctx.email,
      mime(
        Enum.join(
          [
            "2",
            "",
            "On Mon, Oct 6, 2026 at 10:00 AM ACME Support <support@acme.test> wrote:",
            "> How can I help?",
            ">",
            "> 1. Track an order",
            "> 2. Pricing",
            "> 3. Talk to a human"
          ],
          "\r\n"
        ),
        ["In-Reply-To: <#{message_id}>"]
      )
    )

    {email_answer, _agent} = agent_recv(agent, email_turn.conversation_id, "text")

    # --- All four answers arrive in the same normalised shape --------------
    answers = [
      {web_answer, web_offer, "web"},
      {wa_answer, wa_offer, "button"},
      {tg_answer, tg_offer, "keyboard"},
      {email_answer, email_offer, "email"}
    ]

    for {frame, offer, source} <- answers do
      assert frame["from"] == "user"
      assert frame["metadata"]["action"]["source"] == source

      assert answer_shape(frame) == %{
               "text" => "/pricing",
               "action" => @answer,
               "replyTo" => offer.id
             }

      stored = Activities.get_activity!(frame["id"])
      assert stored.reply_to_id == offer.id
      assert stored.metadata["action"] == Map.put(@answer, "source", source)
    end
  end
end
