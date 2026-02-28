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
