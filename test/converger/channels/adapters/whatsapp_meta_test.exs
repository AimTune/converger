defmodule Converger.Channels.Adapters.WhatsAppMetaTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.Adapters.WhatsAppMeta

  @channel %{type: "whatsapp_meta", config: %{}}

  describe "parse_status_update/2" do
    test "parses delivered status" do
      params = whatsapp_status_webhook("wamid.123", "delivered")

      assert {:ok, [update]} = WhatsAppMeta.parse_status_update(@channel, params)
      assert update["provider_message_id"] == "wamid.123"
      assert update["status"] == "delivered"
      assert update["recipient_id"] == "5511999999999"
      assert update["timestamp"] == "1709035200"
    end

    test "parses read status" do
      params = whatsapp_status_webhook("wamid.456", "read")

      assert {:ok, [update]} = WhatsAppMeta.parse_status_update(@channel, params)
      assert update["status"] == "read"
    end

    test "parses sent status" do
      params = whatsapp_status_webhook("wamid.789", "sent")

      assert {:ok, [update]} = WhatsAppMeta.parse_status_update(@channel, params)
      assert update["status"] == "sent"
    end

    test "parses failed status with error" do
      params = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "statuses" => [
                    %{
                      "id" => "wamid.err",
                      "status" => "failed",
                      "timestamp" => "1709035200",
                      "recipient_id" => "5511999999999",
                      "errors" => [%{"title" => "Message expired", "code" => 131_026}]
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, [update]} = WhatsAppMeta.parse_status_update(@channel, params)
      assert update["status"] == "failed"
      assert update["error"] == "Message expired"
    end

    test "handles multiple statuses in a single webhook" do
      params = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "statuses" => [
                    %{
                      "id" => "wamid.a",
                      "status" => "delivered",
                      "timestamp" => "1709035200",
                      "recipient_id" => "5511999999999"
                    },
                    %{
                      "id" => "wamid.b",
                      "status" => "read",
                      "timestamp" => "1709035201",
                      "recipient_id" => "5511999999999"
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, updates} = WhatsAppMeta.parse_status_update(@channel, params)
      assert length(updates) == 2
      assert Enum.at(updates, 0)["status"] == "delivered"
      assert Enum.at(updates, 1)["status"] == "read"
    end

    test "returns :ignore for message-only payload" do
      params = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{"id" => "wamid.msg", "from" => "123", "text" => %{"body" => "hi"}}
                  ],
                  "metadata" => %{"phone_number_id" => "1234"}
                }
              }
            ]
          }
        ]
      }

      assert :ignore = WhatsAppMeta.parse_status_update(@channel, params)
    end

    test "returns :ignore for empty payload" do
      assert :ignore = WhatsAppMeta.parse_status_update(@channel, %{})
    end
  end

  describe "parse_inbound/2" do
    test "parses every message across entries and changes" do
      params = %{
        "entry" => [
          %{
            "changes" => [
              %{"value" => message_value([text_message("wamid.1", "one")])},
              %{"value" => message_value([text_message("wamid.2", "two")])}
            ]
          },
          %{"changes" => [%{"value" => message_value([text_message("wamid.3", "three")])}]}
        ]
      }

      assert {:ok, messages} = WhatsAppMeta.parse_inbound(@channel, params)
      assert Enum.map(messages, & &1["text"]) == ["one", "two", "three"]
      assert Enum.map(messages, & &1["idempotency_key"]) == ["wamid.1", "wamid.2", "wamid.3"]
    end

    test "parses several messages in one change" do
      params = webhook([text_message("wamid.a", "a"), text_message("wamid.b", "b")])

      assert {:ok, [first, second]} = WhatsAppMeta.parse_inbound(@channel, params)
      assert first["sender"] == "16505551234"
      assert first["metadata"]["whatsapp_message_id"] == "wamid.a"
      assert first["metadata"]["profile_name"] == "Sheena Nelson"
      assert first["metadata"]["phone_number_id"] == "106540352242922"
      assert second["text"] == "b"
    end

    test "maps an image to an attachment stub with the provider media id" do
      image = %{
        "from" => "16505551234",
        "id" => "wamid.img",
        "timestamp" => "1749416383",
        "type" => "image",
        "image" => %{
          "caption" => "look",
          "mime_type" => "image/jpeg",
          "sha256" => "abc",
          "id" => "media-123"
        }
      }

      assert {:ok, [message]} = WhatsAppMeta.parse_inbound(@channel, webhook([image]))
      assert message["text"] == "look"

      assert [
               %{
                 "contentType" => "image/jpeg",
                 "providerMediaId" => "media-123",
                 "provider" => "whatsapp_meta"
               }
             ] = message["attachments"]

      assert message["metadata"]["whatsapp_type"] == "image"
    end

    test "maps documents, locations, interactive replies and reactions" do
      messages = [
        %{
          "from" => "1",
          "id" => "wamid.doc",
          "type" => "document",
          "document" => %{"id" => "m1", "mime_type" => "application/pdf", "filename" => "a.pdf"}
        },
        %{
          "from" => "1",
          "id" => "wamid.loc",
          "type" => "location",
          "location" => %{"latitude" => 1.5, "longitude" => 2.5, "name" => "HQ"}
        },
        %{
          "from" => "1",
          "id" => "wamid.btn",
          "type" => "interactive",
          "interactive" => %{
            "type" => "button_reply",
            "button_reply" => %{"id" => "yes", "title" => "Yes"}
          }
        },
        %{
          "from" => "1",
          "id" => "wamid.react",
          "type" => "reaction",
          "reaction" => %{"message_id" => "wamid.orig", "emoji" => "👍"}
        }
      ]

      assert {:ok, [doc, loc, btn, react]} =
               WhatsAppMeta.parse_inbound(@channel, webhook(messages))

      assert [%{"contentType" => "application/pdf", "name" => "a.pdf", "providerMediaId" => "m1"}] =
               doc["attachments"]

      assert [%{"content" => %{"latitude" => 1.5, "longitude" => 2.5}}] = loc["attachments"]
      assert loc["text"] == "HQ"
      assert btn["text"] == "Yes"
      assert btn["metadata"]["interactive_reply"]["id"] == "yes"
      assert react["type"] == "event"
      assert react["metadata"]["reaction"] == %{"message_id" => "wamid.orig", "emoji" => "👍"}
    end

    test "keeps the reply-to context" do
      reply =
        "wamid.reply"
        |> text_message("answer")
        |> Map.put("context", %{"from" => "15550783881", "id" => "wamid.original"})

      assert {:ok, [message]} = WhatsAppMeta.parse_inbound(@channel, webhook([reply]))
      assert message["metadata"]["reply_to"] == "wamid.original"
    end

    test "returns an empty list for a status-only payload" do
      assert {:ok, []} =
               WhatsAppMeta.parse_inbound(@channel, whatsapp_status_webhook("wamid.1", "read"))
    end

    test "returns an error for a non Cloud API payload" do
      assert {:error, _} = WhatsAppMeta.parse_inbound(@channel, %{"text" => "hi"})
    end
  end

  describe "parse_status_update/2 batches" do
    test "parses statuses from every entry" do
      params = %{
        "entry" => [
          whatsapp_status_webhook("wamid.x", "delivered")["entry"] |> hd(),
          whatsapp_status_webhook("wamid.y", "read")["entry"] |> hd()
        ]
      }

      assert {:ok, updates} = WhatsAppMeta.parse_status_update(@channel, params)
      assert Enum.map(updates, & &1["provider_message_id"]) == ["wamid.x", "wamid.y"]
    end
  end

  describe "graph_api_version/1" do
    test "defaults to a current version and can be overridden per channel" do
      refute WhatsAppMeta.graph_api_version(@channel) == "v18.0"

      assert WhatsAppMeta.graph_api_version(%{config: %{"graph_api_version" => "v99.0"}}) ==
               "v99.0"
    end
  end

  defp text_message(id, body) do
    %{
      "from" => "16505551234",
      "id" => id,
      "timestamp" => "1749416383",
      "type" => "text",
      "text" => %{"body" => body}
    }
  end

  defp message_value(messages) do
    %{
      "messaging_product" => "whatsapp",
      "metadata" => %{
        "display_phone_number" => "15550783881",
        "phone_number_id" => "106540352242922"
      },
      "contacts" => [%{"profile" => %{"name" => "Sheena Nelson"}, "wa_id" => "16505551234"}],
      "messages" => messages
    }
  end

  defp webhook(messages) do
    %{"entry" => [%{"changes" => [%{"value" => message_value(messages), "field" => "messages"}]}]}
  end

  defp whatsapp_status_webhook(message_id, status) do
    %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "statuses" => [
                  %{
                    "id" => message_id,
                    "status" => status,
                    "timestamp" => "1709035200",
                    "recipient_id" => "5511999999999"
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  end
end
