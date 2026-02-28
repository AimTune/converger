defmodule ConvergerWeb.StatusWebhookTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures
  import Converger.DeliveriesFixtures

  alias Converger.Deliveries

  setup do
    tenant = tenant_fixture()
    channel = webhook_channel_fixture(tenant, %{mode: "duplex"})
    conversation = conversation_fixture(tenant, channel)
    activity = activity_fixture(tenant, conversation)
    delivery = delivery_fixture(activity, channel)

    # Mark delivery as sent with a provider message ID
    {:ok, sent_delivery} =
      Deliveries.mark_sent(delivery, %{"whatsapp_message_id" => "wamid.test-123"})

    %{
      tenant: tenant,
      channel: channel,
      conversation: conversation,
      activity: activity,
      delivery: sent_delivery
    }
  end

  describe "POST /api/v1/channels/:channel_id/status" do
    test "processes status update with provider_message_id", %{
      conn: conn,
      channel: channel,
      delivery: delivery
    } do
      conn =
        post(conn, ~p"/api/v1/channels/#{channel.id}/status", %{
          "provider_message_id" => "wamid.test-123",
          "status" => "delivered"
        })

      assert json_response(conn, 200)["status"] == "accepted"
      assert json_response(conn, 200)["receipts_processed"] == 1

      updated = Deliveries.get_delivery!(delivery.id)
      assert updated.status == "delivered"
      assert updated.delivered_at != nil
    end

    test "processes status update with delivery_id", %{
      conn: conn,
      channel: channel,
      delivery: delivery
    } do
      conn =
        post(conn, ~p"/api/v1/channels/#{channel.id}/status", %{
          "delivery_id" => delivery.id,
          "status" => "read"
        })

      assert json_response(conn, 200)["receipts_processed"] == 1

      updated = Deliveries.get_delivery!(delivery.id)
      assert updated.status == "read"
      assert updated.read_at != nil
    end

    test "works for outbound-only channels", %{conn: conn, tenant: tenant} do
      outbound_channel = webhook_channel_fixture(tenant, %{mode: "outbound"})
      conversation = conversation_fixture(tenant, outbound_channel)
      activity = activity_fixture(tenant, conversation)
      delivery = delivery_fixture(activity, outbound_channel)
      {:ok, _} = Deliveries.mark_sent(delivery, %{"whatsapp_message_id" => "wamid.out-123"})

      conn =
        post(conn, ~p"/api/v1/channels/#{outbound_channel.id}/status", %{
          "provider_message_id" => "wamid.out-123",
          "status" => "delivered"
        })

      assert json_response(conn, 200)["status"] == "accepted"
    end

    test "returns 200 for unknown provider_message_id", %{conn: conn, channel: channel} do
      conn =
        post(conn, ~p"/api/v1/channels/#{channel.id}/status", %{
          "provider_message_id" => "unknown-id",
          "status" => "delivered"
        })

      # Still returns 200 - best effort processing
      assert json_response(conn, 200)["receipts_processed"] == 0
    end
  end

  describe "POST /api/v1/channels/:channel_id/inbound with WhatsApp status" do
    setup do
      tenant = tenant_fixture()

      {:ok, channel} =
        Converger.Channels.create_channel(%{
          name: "WA Channel #{System.unique_integer()}",
          type: "whatsapp_meta",
          mode: "duplex",
          status: "active",
          tenant_id: tenant.id,
          config: %{
            "phone_number_id" => "123456",
            "access_token" => "token",
            "verify_token" => "verify"
          }
        })

      conversation = conversation_fixture(tenant, channel)
      activity = activity_fixture(tenant, conversation)
      delivery = delivery_fixture(activity, channel)

      {:ok, sent} =
        Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.wa-status-test"})

      %{wa_channel: channel, wa_delivery: sent}
    end

    test "processes WhatsApp status webhook via /inbound", %{
      conn: conn,
      wa_channel: channel,
      wa_delivery: delivery
    } do
      params = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "statuses" => [
                    %{
                      "id" => "wamid.wa-status-test",
                      "status" => "delivered",
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

      conn = post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", params)

      assert json_response(conn, 200)["status"] == "accepted"
      assert json_response(conn, 200)["receipts_processed"] == 1

      updated = Deliveries.get_delivery!(delivery.id)
      assert updated.status == "delivered"
    end
  end
end
