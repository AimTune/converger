defmodule Converger.Channels.Adapters.TelegramTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.Adapter
  alias Converger.Channels.Adapters.Telegram
  alias Converger.Channels.DeliveryError

  @stub Telegram
  @token "7000000001:AAFakeTokenForTests"
  @channel %{
    id: nil,
    tenant_id: nil,
    type: "telegram",
    config: %{"bot_token" => @token, "secret_token" => "s3cr3t_Token-1"}
  }

  defp fixture(name) do
    "test/fixtures/telegram/#{name}.json" |> File.read!() |> Jason.decode!()
  end

  # Records every Bot API call as {:telegram, method, params} and answers
  # with `result_fun.(method, params)`.
  defp stub_api(result_fun \\ fn _method, _params -> %{"message_id" => 1} end) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      method = conn.request_path |> String.split("/") |> List.last()
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = if body == "", do: %{}, else: Jason.decode!(body)
      send(test_pid, {:telegram, conn.request_path, method, params})
      Req.Test.json(conn, %{"ok" => true, "result" => result_fun.(method, params)})
    end)
  end

  defp activity(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        conversation_id: nil,
        type: "message",
        text: "hello",
        attachments: [],
        metadata: %{"chat_id" => "123456789"}
      },
      attrs
    )
  end

  test "is registered as a duplex built-in type" do
    assert {:ok, Telegram} = Adapter.adapter_for("telegram")
    assert Telegram.supported_modes() == ~w(inbound outbound duplex)
    assert Adapter.capability?("telegram", :provider_ack)
    assert Adapter.supports?("telegram", :register_webhook, 2)
  end

  describe "config" do
    test "requires bot_token, and secret_token on signed channels" do
      assert {:error, "telegram config missing: bot_token"} =
               Adapter.validate_config("telegram", %{})

      assert :ok = Adapter.validate_config("telegram", %{"bot_token" => @token})

      assert {:error, message} =
               Adapter.validate_config("telegram", %{"bot_token" => @token},
                 require_signature: true
               )

      assert message =~ "secret_token"
    end

    test "checks the secret token alphabet, parse mode and allowed updates" do
      base = %{"bot_token" => @token}

      assert {:error, message} =
               Adapter.validate_config("telegram", Map.put(base, "secret_token", "has space"))

      assert message =~ "secret_token"

      assert {:error, _} =
               Adapter.validate_config("telegram", Map.put(base, "parse_mode", "BBCode"))

      assert :ok = Adapter.validate_config("telegram", Map.put(base, "parse_mode", "HTML"))

      assert :ok =
               Adapter.validate_config(
                 "telegram",
                 Map.put(base, "allowed_updates", "message, callback_query")
               )

      assert {:error, _} =
               Adapter.validate_config("telegram", Map.put(base, "allowed_updates", ["message"]))
    end
  end

  describe "verify_inbound_signature/3" do
    test "accepts the configured secret token" do
      headers = [{"x-telegram-bot-api-secret-token", "s3cr3t_Token-1"}]
      assert :ok = Telegram.verify_inbound_signature(@channel, headers, "{}")
    end

    test "rejects a wrong or missing secret token once one is configured" do
      assert {:error, :invalid_secret_token} =
               Telegram.verify_inbound_signature(
                 @channel,
                 [{"x-telegram-bot-api-secret-token", "wrong"}],
                 "{}"
               )

      assert {:error, :missing_secret_token} =
               Telegram.verify_inbound_signature(@channel, [], "{}")
    end

    test "is :missing without a configured secret (require_signature decides)" do
      channel = %{@channel | config: %{"bot_token" => @token}}

      assert :missing =
               Telegram.verify_inbound_signature(
                 channel,
                 [{"x-telegram-bot-api-secret-token", "anything"}],
                 "{}"
               )
    end
  end

  describe "parse_inbound/2" do
    test "a text message" do
      assert {:ok, [message]} = Telegram.parse_inbound(@channel, fixture("message_text"))

      assert message["type"] == "message"
      assert message["text"] == "Where is my order?"
      assert message["sender"] == "123456789"
      assert message["idempotency_key"] == "123456789:41"

      assert message["participant"] == %{
               "external_id" => "123456789",
               "display_name" => "Ada Lovelace"
             }

      assert message["metadata"]["telegram_update_id"] == 912_345_601
      assert message["metadata"]["telegram_chat_type"] == "private"
      assert message["metadata"]["username"] == "ada_l"
      assert message["reply_to_provider_id"] == nil
    end

    test "a reply names its target by chat and message id" do
      assert {:ok, [message]} = Telegram.parse_inbound(@channel, fixture("message_reply"))
      assert message["reply_to_provider_id"] == "123456789:41"
      assert message["metadata"]["reply_to"] == 41
    end

    test "a group message: the chat is the participant, the user the sender" do
      assert {:ok, [message]} = Telegram.parse_inbound(@channel, fixture("group_message"))

      assert message["sender"] == "222333444"
      assert message["participant"]["external_id"] == "-1001234567890"
      assert message["participant"]["display_name"] == "Grace"
      assert message["idempotency_key"] == "-1001234567890:7"
    end

    test "an edited message is a messageUpdate of the original" do
      assert {:ok, [message]} = Telegram.parse_inbound(@channel, fixture("edited_message"))

      assert message["type"] == "messageUpdate"
      assert message["text"] == "Where is my order #1042?"
      assert message["reply_to_provider_id"] == "123456789:41"
      assert message["idempotency_key"] == "123456789:41:edit:1760140920"
      assert message["metadata"]["edit_date"] == 1_760_140_920
    end

    test "a callback query is an event, and is answered" do
      stub_api(fn "answerCallbackQuery", _ -> true end)

      assert {:ok, [message]} = Telegram.parse_inbound(@channel, fixture("callback_query"))

      assert message["type"] == "event"
      assert message["text"] == "track_order"
      assert message["sender"] == "123456789"
      assert message["idempotency_key"] == "callback:4382bfdwdsb323b2d9"
      assert message["reply_to_provider_id"] == "123456789:42"
      assert message["metadata"]["name"] == "telegram.callback_query"
      assert message["metadata"]["callback_data"] == "track_order"

      assert_receive {:telegram, _, "answerCallbackQuery",
                      %{"callback_query_id" => "4382bfdwdsb323b2d9"}}
    end

    test "a press on an answer-key button is a message carrying the answer (#68)" do
      stub_api(fn "answerCallbackQuery", _ -> true end)
      ref = "a:6f1c2a4e-0b7d-4c55-9a1e-3d2f8e7b9c10:1"

      update =
        fixture("callback_query")
        |> put_in(["callback_query", "data"], ref)
        |> put_in(["callback_query", "message", "reply_markup"], %{
          "inline_keyboard" => [
            [%{"text" => "Track", "callback_data" => "a:6f1c2a4e-0b7d-4c55-9a1e-3d2f8e7b9c10:0"}],
            [%{"text" => "Talk to a human", "callback_data" => ref}]
          ]
        })

      assert {:ok, [message]} = Telegram.parse_inbound(@channel, update)

      assert message["type"] == "message"
      assert message["text"] == "Talk to a human"

      assert message["answer"] == %{
               "ref" => ref,
               "source" => "keyboard",
               "label" => "Talk to a human"
             }

      assert message["reply_to_provider_id"] == "123456789:42"
    end

    test "a reaction is a messageReaction on the reacted-to message" do
      assert {:ok, [message]} = Telegram.parse_inbound(@channel, fixture("message_reaction"))

      assert message["type"] == "messageReaction"
      assert message["text"] == "👍"
      assert message["reply_to_provider_id"] == "123456789:41"
      assert message["idempotency_key"] == "update:912345605"
    end

    test "a removed reaction has an empty text" do
      update =
        put_in(fixture("message_reaction"), ["message_reaction", "new_reaction"], [])
        |> put_in(["message_reaction", "old_reaction"], [%{"type" => "emoji", "emoji" => "👍"}])

      assert {:ok, [%{"type" => "messageReaction", "text" => ""}]} =
               Telegram.parse_inbound(@channel, update)
    end

    test "media keeps the Telegram file id when it is not stored" do
      # A channel without a tenant (no storage): the file is not downloaded.
      assert {:ok, [message]} = Telegram.parse_inbound(@channel, fixture("message_photo"))

      assert message["text"] == "The damaged box"

      assert [
               %{
                 "contentType" => "image/jpeg",
                 "channelData" => %{
                   "provider" => "telegram",
                   "kind" => "photo",
                   "fileId" => "AgACAgQAAxkBAAMlarge",
                   "width" => 1280
                 }
               }
             ] = message["attachments"]

      assert {:ok, [voice]} = Telegram.parse_inbound(@channel, fixture("message_voice"))

      assert [%{"contentType" => "audio/ogg", "channelData" => %{"kind" => "voice"}}] =
               voice["attachments"]

      assert {:ok, [doc]} = Telegram.parse_inbound(@channel, fixture("message_document"))
      assert [%{"contentType" => "application/pdf", "name" => "invoice.pdf"}] = doc["attachments"]
    end

    test "other update types parse to no messages" do
      assert {:ok, []} = Telegram.parse_inbound(@channel, fixture("my_chat_member"))
    end

    test "a payload that is not an Update is an error" do
      assert {:error, _} = Telegram.parse_inbound(@channel, %{"entry" => []})
    end
  end

  describe "deliver_activity/2" do
    test "sends text with the configured parse mode" do
      stub_api(fn "sendMessage", _ -> %{"message_id" => 50, "chat" => %{"id" => 123_456_789}} end)
      channel = put_in(@channel, [:config, "parse_mode"], "HTML")

      assert {:ok, %{provider_message_id: "123456789:50"}} =
               Telegram.deliver_activity(channel, activity(%{text: "<b>On it</b>"}))

      assert_received {:telegram, path, "sendMessage", params}
      assert path == "/bot#{@token}/sendMessage"

      assert params == %{
               "chat_id" => "123456789",
               "text" => "<b>On it</b>",
               "parse_mode" => "HTML"
             }
    end

    test "sends images by URL with sendPhoto and other files with sendDocument" do
      stub_api()

      attachments = [
        %{"contentType" => "image/png", "contentUrl" => "https://cdn.example.com/a.png"},
        %{
          "contentType" => "application/pdf",
          "contentUrl" => "https://cdn.example.com/invoice.pdf",
          "name" => "invoice.pdf"
        }
      ]

      assert {:ok, %{telegram_messages: 3}} =
               Telegram.deliver_activity(@channel, activity(%{attachments: attachments}))

      assert_received {:telegram, _, "sendPhoto", %{"photo" => "https://cdn.example.com/a.png"}}

      assert_received {:telegram, _, "sendDocument",
                       %{
                         "document" => "https://cdn.example.com/invoice.pdf",
                         "caption" => "invoice.pdf"
                       }}

      assert_received {:telegram, _, "sendMessage", %{"text" => "hello"}}
    end

    test "turns card buttons into an inline keyboard" do
      stub_api()

      card = %{
        "contentType" => "application/vnd.converger.card.hero",
        "content" => %{
          "title" => "Your order",
          "text" => "Shipped yesterday",
          "buttons" => [
            %{"type" => "openUrl", "title" => "Track", "value" => "https://example.com/t/1"},
            %{"type" => "postBack", "title" => "Talk to a human", "value" => "handoff"},
            %{"type" => "imBack", "title" => "Thanks"},
            %{"type" => "postBack", "title" => "Too long", "value" => String.duplicate("x", 65)}
          ]
        }
      }

      assert {:ok, _} =
               Telegram.deliver_activity(@channel, activity(%{text: nil, attachments: [card]}))

      assert_received {:telegram, _, "sendMessage", params}
      assert params["text"] == "Your order\nShipped yesterday"

      assert params["reply_markup"] == %{
               "inline_keyboard" => [
                 [%{"text" => "Track", "url" => "https://example.com/t/1"}],
                 [%{"text" => "Talk to a human", "callback_data" => "handoff"}],
                 [%{"text" => "Thanks", "callback_data" => "Thanks"}]
               ]
             }
    end

    test "typed buttons are an inline keyboard of answer keys, links as URL buttons (#68)" do
      stub_api()
      id = Ecto.UUID.generate()

      buttons =
        activity(%{
          id: id,
          text: "fallback",
          message_type: "buttons",
          payload: %{
            "data" => %{
              "text" => "How can I help?",
              "buttons" => [
                %{"label" => "Track an order", "value" => "/track"},
                %{"label" => "Pricing", "url" => "https://example.com/pricing"}
              ]
            }
          }
        })

      assert {:ok, %{telegram_messages: 1}} = Telegram.deliver_activity(@channel, buttons)
      assert_received {:telegram, _, "sendMessage", params}
      assert params["text"] == "How can I help?"

      assert params["reply_markup"] == %{
               "inline_keyboard" => [
                 [%{"text" => "Track an order", "callback_data" => "a:#{id}:0"}],
                 [%{"text" => "Pricing", "url" => "https://example.com/pricing"}]
               ]
             }

      assert byte_size("a:#{id}:0") <= 64
    end

    test "a typed carousel is one photo with caption and keyboard per card (#68)" do
      stub_api()
      id = Ecto.UUID.generate()

      carousel =
        activity(%{
          id: id,
          message_type: "carousel",
          payload: %{
            "data" => %{
              "cards" => [
                %{
                  "title" => "Basic",
                  "subtitle" => "9 USD",
                  "image" => "https://cdn.example.com/basic.png",
                  "buttons" => [%{"label" => "Pick", "value" => "basic"}]
                },
                %{"title" => "Pro", "buttons" => [%{"label" => "Pick", "value" => "pro"}]}
              ]
            }
          }
        })

      assert {:ok, %{telegram_messages: 2}} = Telegram.deliver_activity(@channel, carousel)

      assert_received {:telegram, _, "sendPhoto",
                       %{
                         "photo" => "https://cdn.example.com/basic.png",
                         "caption" => "Basic\n9 USD",
                         "reply_markup" => %{"inline_keyboard" => [[%{"callback_data" => first}]]}
                       }}

      assert_received {:telegram, _, "sendMessage",
                       %{
                         "text" => "Pro",
                         "reply_markup" => %{
                           "inline_keyboard" => [[%{"callback_data" => second}]]
                         }
                       }}

      assert first == "a:#{id}:0"
      assert second == "a:#{id}:1"
    end

    test "video, voice, audio, location and contacts use their own methods" do
      stub_api()

      attachments = [
        %{"contentType" => "video/mp4", "contentUrl" => "https://cdn.example.com/v.mp4"},
        %{
          "contentType" => "audio/ogg",
          "contentUrl" => "https://cdn.example.com/v.ogg",
          "channelData" => %{"voice" => true}
        },
        %{"contentType" => "audio/mpeg", "contentUrl" => "https://cdn.example.com/s.mp3"},
        %{
          "contentType" => "application/vnd.converger.location",
          "content" => %{"latitude" => 41.0, "longitude" => 29.0}
        },
        %{
          "contentType" => "application/vnd.converger.contacts",
          "content" => [%{"name" => "Desk", "phones" => ["+90212"]}, %{"name" => "No phone"}]
        }
      ]

      assert {:ok, %{telegram_messages: 5}} =
               Telegram.deliver_activity(
                 @channel,
                 activity(%{text: nil, attachments: attachments})
               )

      assert_received {:telegram, _, "sendVideo", %{"video" => "https://cdn.example.com/v.mp4"}}
      assert_received {:telegram, _, "sendVoice", %{"voice" => "https://cdn.example.com/v.ogg"}}
      assert_received {:telegram, _, "sendAudio", %{"audio" => "https://cdn.example.com/s.mp3"}}
      assert_received {:telegram, _, "sendLocation", %{"latitude" => 41.0, "longitude" => 29.0}}

      assert_received {:telegram, _, "sendContact",
                       %{"phone_number" => "+90212", "first_name" => "Desk"}}
    end

    test "without a recipient the failure is permanent" do
      assert {:error, %DeliveryError{retryable?: false}} =
               Telegram.deliver_activity(@channel, activity(%{metadata: %{}}))
    end

    test "inbound Telegram metadata is not used as the recipient" do
      assert {:error, %DeliveryError{retryable?: false}} =
               Telegram.deliver_activity(
                 @channel,
                 activity(%{metadata: %{"telegram_chat_id" => "123456789"}})
               )
    end

    test "classifies Bot API errors, honouring retry_after" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{
          "ok" => false,
          "error_code" => 429,
          "description" => "Too Many Requests: retry after 7",
          "parameters" => %{"retry_after" => 7}
        })
      end)

      assert {:error, %DeliveryError{retryable?: true, retry_after_ms: 7000, reason: reason}} =
               Telegram.deliver_activity(@channel, activity(%{}))

      assert reason =~ "Too Many Requests"
      refute reason =~ @token

      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{
          "ok" => false,
          "error_code" => 403,
          "description" => "Forbidden: bot was blocked by the user"
        })
      end)

      assert {:error, %DeliveryError{retryable?: false}} =
               Telegram.deliver_activity(@channel, activity(%{}))
    end
  end

  describe "signals and setup" do
    test "send_typing sends the typing chat action" do
      stub_api(fn _, _ -> true end)

      assert :ok =
               Telegram.send_typing(@channel, %{
                 conversation_id: "c",
                 recipient: "123456789",
                 provider_message_id: nil,
                 is_typing: true
               })

      assert_received {:telegram, _, "sendChatAction",
                       %{"chat_id" => "123456789", "action" => "typing"}}

      assert :ok =
               Telegram.send_typing(@channel, %{
                 conversation_id: "c",
                 recipient: "123456789",
                 provider_message_id: nil,
                 is_typing: false
               })

      refute_received {:telegram, _, _, _}
    end

    test "register_webhook calls setWebhook with the secret and allowed updates" do
      stub_api(fn "setWebhook", _ -> true end)
      url = "https://converger.example.com/api/v1/channels/abc/inbound"

      assert :ok = Telegram.register_webhook(@channel, url)

      assert_received {:telegram, _, "setWebhook", params}
      assert params["url"] == url
      assert params["secret_token"] == "s3cr3t_Token-1"

      assert params["allowed_updates"] ==
               ~w(message edited_message callback_query message_reaction)
    end

    test "register_webhook reports the Bot API error" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "ok" => false,
          "error_code" => 400,
          "description" => "Bad Request: bad webhook: An HTTPS URL must be provided for webhook"
        })
      end)

      assert {:error, message} = Telegram.register_webhook(@channel, "http://localhost/x")
      assert message =~ "HTTPS URL must be provided"
    end

    test "health_probe calls getMe" do
      stub_api(fn "getMe", _ -> %{"id" => 7_000_000_001, "is_bot" => true} end)
      assert :ok = Telegram.health_probe(@channel)
      assert_received {:telegram, _, "getMe", _}
    end

    test "the Bot API base URL is not a channel setting" do
      refute Enum.any?(Telegram.config_schema(), &(&1.name == "api_base_url"))
      assert Telegram.api_base_url() == "https://api.telegram.org"
    end
  end
end
