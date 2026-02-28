defmodule Converger.Channels.Adapters.WebhookTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.Adapters.Webhook

  @channel %{type: "webhook", config: %{}}

  describe "parse_status_update/2" do
    test "parses status update with provider_message_id" do
      params = %{
        "provider_message_id" => "ext-msg-123",
        "status" => "delivered",
        "timestamp" => "2026-02-27T12:00:00Z"
      }

      assert {:ok, [update]} = Webhook.parse_status_update(@channel, params)
      assert update["provider_message_id"] == "ext-msg-123"
      assert update["status"] == "delivered"
      assert update["timestamp"] == "2026-02-27T12:00:00Z"
    end

    test "parses status update with delivery_id" do
      delivery_id = Ecto.UUID.generate()

      params = %{
        "delivery_id" => delivery_id,
        "status" => "read"
      }

      assert {:ok, [update]} = Webhook.parse_status_update(@channel, params)
      assert update["delivery_id"] == delivery_id
      assert update["status"] == "read"
    end

    test "includes error for failed status" do
      params = %{
        "provider_message_id" => "ext-msg-456",
        "status" => "failed",
        "error" => "Recipient unreachable"
      }

      assert {:ok, [update]} = Webhook.parse_status_update(@channel, params)
      assert update["status"] == "failed"
      assert update["error"] == "Recipient unreachable"
    end

    test "returns :ignore for missing status field" do
      params = %{"provider_message_id" => "ext-msg-789"}
      assert :ignore = Webhook.parse_status_update(@channel, params)
    end

    test "returns :ignore for missing identifier" do
      params = %{"status" => "delivered"}
      assert :ignore = Webhook.parse_status_update(@channel, params)
    end

    test "returns :ignore for empty payload" do
      assert :ignore = Webhook.parse_status_update(@channel, %{})
    end
  end
end
