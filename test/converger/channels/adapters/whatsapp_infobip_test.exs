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
