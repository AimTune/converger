defmodule Converger.Channels.Adapters.WhatsAppInfobipTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.Adapters.WhatsAppInfobip

  @channel %{type: "whatsapp_infobip", config: %{}}

  describe "parse_status_update/2" do
    test "parses DELIVERED status" do
      params = infobip_dlr("msg-123", "DELIVERED")

      assert {:ok, [update]} = WhatsAppInfobip.parse_status_update(@channel, params)
      assert update["provider_message_id"] == "msg-123"
      assert update["status"] == "delivered"
      assert update["recipient_id"] == "5511999999999"
    end

    test "parses SEEN status as read" do
      params = infobip_dlr("msg-456", "SEEN")

      assert {:ok, [update]} = WhatsAppInfobip.parse_status_update(@channel, params)
      assert update["status"] == "read"
    end

    test "parses REJECTED status as failed" do
      params = infobip_dlr("msg-789", "REJECTED")

      assert {:ok, [update]} = WhatsAppInfobip.parse_status_update(@channel, params)
      assert update["status"] == "failed"
    end

    test "parses UNDELIVERABLE status as failed" do
      params = infobip_dlr("msg-000", "UNDELIVERABLE")

      assert {:ok, [update]} = WhatsAppInfobip.parse_status_update(@channel, params)
      assert update["status"] == "failed"
    end

    test "parses PENDING status as sent" do
      params = infobip_dlr("msg-111", "PENDING")

      assert {:ok, [update]} = WhatsAppInfobip.parse_status_update(@channel, params)
      assert update["status"] == "sent"
    end

    test "includes error description when present" do
      params = %{
        "results" => [
          %{
            "messageId" => "msg-err",
            "to" => "5511999999999",
            "status" => %{"groupName" => "REJECTED"},
            "error" => %{"description" => "Invalid number"},
            "doneAt" => "2026-02-27T12:00:00Z"
          }
        ]
      }

      assert {:ok, [update]} = WhatsAppInfobip.parse_status_update(@channel, params)
      assert update["error"] == "Invalid number"
    end

    test "returns :ignore for payload without status groupName" do
      params = %{
        "results" => [
          %{"messageId" => "msg-123", "from" => "sender", "message" => %{"text" => "hello"}}
        ]
      }

      assert :ignore = WhatsAppInfobip.parse_status_update(@channel, params)
    end

    test "returns :ignore for empty payload" do
      assert :ignore = WhatsAppInfobip.parse_status_update(@channel, %{})
    end
  end

  describe "parse_status_update/2 batches" do
    test "parses every delivery report in results" do
      params = %{
        "results" =>
          infobip_dlr("msg-1", "DELIVERED")["results"] ++ infobip_dlr("msg-2", "SEEN")["results"]
      }

      assert {:ok, updates} = WhatsAppInfobip.parse_status_update(@channel, params)
      assert Enum.map(updates, & &1["provider_message_id"]) == ["msg-1", "msg-2"]
      assert Enum.map(updates, & &1["status"]) == ["delivered", "read"]
    end
  end

  describe "parse_inbound/2" do
    test "parses every message in results" do
      params = %{
        "results" => [
          inbound("ib-1", %{"type" => "TEXT", "text" => "one"}),
          inbound("ib-2", %{"type" => "TEXT", "text" => "two"}),
          inbound("ib-3", %{"type" => "TEXT", "text" => "three"})
        ]
      }

      assert {:ok, messages} = WhatsAppInfobip.parse_inbound(@channel, params)
      assert Enum.map(messages, & &1["text"]) == ["one", "two", "three"]
      assert Enum.map(messages, & &1["idempotency_key"]) == ["ib-1", "ib-2", "ib-3"]
      assert hd(messages)["sender"] == "5511999999999"
      assert hd(messages)["metadata"]["profile_name"] == "Frank"
    end

    test "maps an image to an attachment stub" do
      params = %{
        "results" => [
          inbound("ib-img", %{
            "type" => "IMAGE",
            "url" => "https://api.infobip.com/whatsapp/1/media/abc",
            "caption" => "look"
          })
        ]
      }

      assert {:ok, [message]} = WhatsAppInfobip.parse_inbound(@channel, params)
      assert message["text"] == "look"

      assert [
               %{
                 "contentType" => "image/*",
                 "provider" => "whatsapp_infobip",
                 "providerMediaUrl" => "https://api.infobip.com/whatsapp/1/media/abc"
               }
             ] = message["attachments"]
    end

    test "skips delivery reports" do
      assert {:ok, []} = WhatsAppInfobip.parse_inbound(@channel, infobip_dlr("msg-1", "SEEN"))
    end

    test "returns an error without results" do
      assert {:error, _} = WhatsAppInfobip.parse_inbound(@channel, %{})
    end
  end

  defp inbound(message_id, message) do
    %{
      "from" => "5511999999999",
      "to" => "447860099299",
      "integrationType" => "WHATSAPP",
      "receivedAt" => "2026-02-27T12:00:00.000+0000",
      "messageId" => message_id,
      "message" => message,
      "contact" => %{"name" => "Frank"}
    }
  end

  defp infobip_dlr(message_id, group_name) do
    %{
      "results" => [
        %{
          "messageId" => message_id,
          "to" => "5511999999999",
          "status" => %{"groupName" => group_name},
          "doneAt" => "2026-02-27T12:00:00Z"
        }
      ]
    }
  end
end
