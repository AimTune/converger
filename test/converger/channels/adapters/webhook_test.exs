defmodule Converger.Channels.Adapters.WebhookTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.Adapters.Webhook

  @channel %{type: "webhook", config: %{}}
  @url "https://hooks.example.com/in"

  describe "validate_config/1" do
    test "requires a valid http(s) url" do
      assert {:error, _} = Webhook.validate_config(%{})
      assert {:error, _} = Webhook.validate_config(%{"url" => "ftp://example.com"})
      assert :ok = Webhook.validate_config(%{"url" => @url})
    end

    test "accepts POST, PUT and PATCH in any case" do
      for method <- ["POST", "put", "Patch", ""] do
        assert :ok = Webhook.validate_config(%{"url" => @url, "method" => method})
      end
    end

    test "unknown methods are a validation error, not a crash" do
      for method <- ["DELETE", "GET", "definitely_not_an_existing_atom_xyz", 42] do
        assert {:error, message} = Webhook.validate_config(%{"url" => @url, "method" => method})
        assert message =~ "method"
      end
    end

    test "rejects reserved and non-string headers" do
      for name <- [
            "Host",
            "content-length",
            "Transfer-Encoding",
            "Connection",
            "X-Converger-Event"
          ] do
        assert {:error, message} =
                 Webhook.validate_config(%{"url" => @url, "headers" => %{name => "x"}})

        assert message =~ "reserved"
      end

      assert {:error, _} = Webhook.validate_config(%{"url" => @url, "headers" => %{"X-A" => 1}})
      assert {:error, _} = Webhook.validate_config(%{"url" => @url, "headers" => ["X-A"]})

      assert :ok =
               Webhook.validate_config(%{"url" => @url, "headers" => %{"Authorization" => "x"}})
    end

    test "validates timeouts and response size limits" do
      assert :ok =
               Webhook.validate_config(%{
                 "url" => @url,
                 "connect_timeout" => 2_000,
                 "receive_timeout" => "30000",
                 "max_response_bytes" => 4096
               })

      assert {:error, _} = Webhook.validate_config(%{"url" => @url, "connect_timeout" => 0})
      assert {:error, _} = Webhook.validate_config(%{"url" => @url, "receive_timeout" => 600_000})

      assert {:error, _} =
               Webhook.validate_config(%{"url" => @url, "max_response_bytes" => "big"})
    end
  end

  describe "parse_inbound/2" do
    test "parses a text message" do
      assert {:ok, [%{"text" => "hi", "sender" => "u1"}]} =
               Webhook.parse_inbound(@channel, %{"text" => "hi", "sender" => "u1"})
    end

    test "rejects a message with no text and no attachments" do
      assert {:error, :empty_inbound_message} = Webhook.parse_inbound(@channel, %{})
      assert {:error, :empty_inbound_message} = Webhook.parse_inbound(@channel, %{"text" => "  "})
    end

    test "accepts attachments without text and non-message types" do
      assert {:ok, _} =
               Webhook.parse_inbound(@channel, %{"attachments" => [%{"url" => "https://x/y"}]})

      assert {:ok, [%{"type" => "typing"}]} =
               Webhook.parse_inbound(@channel, %{"type" => "typing"})
    end
  end

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
