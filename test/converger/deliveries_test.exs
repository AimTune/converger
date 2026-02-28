defmodule Converger.DeliveriesTest do
  use Converger.DataCase

  alias Converger.Deliveries
  alias Converger.Deliveries.Delivery

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures
  import Converger.DeliveriesFixtures

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    activity = activity_fixture(tenant, conversation)
    delivery = delivery_fixture(activity, channel)

    %{
      tenant: tenant,
      channel: channel,
      conversation: conversation,
      activity: activity,
      delivery: delivery
    }
  end

  describe "mark_sent/2" do
    test "sets status to sent with sent_at timestamp", %{delivery: delivery} do
      assert {:ok, updated} = Deliveries.mark_sent(delivery)
      assert updated.status == "sent"
      assert updated.sent_at != nil
      assert updated.attempts == 1
    end

    test "extracts whatsapp_message_id as provider_message_id", %{delivery: delivery} do
      assert {:ok, updated} =
               Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.123"})

      assert updated.provider_message_id == "wamid.123"
      assert updated.metadata[:whatsapp_message_id] == "wamid.123"
    end

    test "extracts infobip_message_id as provider_message_id", %{delivery: delivery} do
      assert {:ok, updated} =
               Deliveries.mark_sent(delivery, %{infobip_message_id: "ibip-456"})

      assert updated.provider_message_id == "ibip-456"
    end

    test "works with no response metadata", %{delivery: delivery} do
      assert {:ok, updated} = Deliveries.mark_sent(delivery)
      assert updated.provider_message_id == nil
    end
  end

  describe "apply_status_update/2" do
    test "advances from sent to delivered", %{delivery: delivery, channel: channel} do
      {:ok, sent} = Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.123"})

      assert {:ok, updated} =
               Deliveries.apply_status_update(channel.id, %{
                 "provider_message_id" => "wamid.123",
                 "status" => "delivered"
               })

      assert updated.status == "delivered"
      assert updated.delivered_at != nil
    end

    test "advances from delivered to read", %{delivery: delivery, channel: channel} do
      {:ok, _sent} = Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.123"})

      {:ok, _} =
        Deliveries.apply_status_update(channel.id, %{
          "provider_message_id" => "wamid.123",
          "status" => "delivered"
        })

      assert {:ok, updated} =
               Deliveries.apply_status_update(channel.id, %{
                 "provider_message_id" => "wamid.123",
                 "status" => "read"
               })

      assert updated.status == "read"
      assert updated.read_at != nil
    end

    test "ignores stale update (delivered after read)", %{delivery: delivery, channel: channel} do
      {:ok, _} = Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.123"})

      {:ok, _} =
        Deliveries.apply_status_update(channel.id, %{
          "provider_message_id" => "wamid.123",
          "status" => "read"
        })

      {:ok, unchanged} =
        Deliveries.apply_status_update(channel.id, %{
          "provider_message_id" => "wamid.123",
          "status" => "delivered"
        })

      assert unchanged.status == "read"
    end

    test "handles failed status", %{delivery: delivery, channel: channel} do
      {:ok, _} = Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.123"})

      assert {:ok, updated} =
               Deliveries.apply_status_update(channel.id, %{
                 "provider_message_id" => "wamid.123",
                 "status" => "failed",
                 "error" => "Message expired"
               })

      assert updated.status == "failed"
      assert updated.last_error == "Message expired"
    end

    test "does not override read with failed", %{delivery: delivery, channel: channel} do
      {:ok, _} = Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.123"})

      {:ok, _} =
        Deliveries.apply_status_update(channel.id, %{
          "provider_message_id" => "wamid.123",
          "status" => "read"
        })

      {:ok, unchanged} =
        Deliveries.apply_status_update(channel.id, %{
          "provider_message_id" => "wamid.123",
          "status" => "failed"
        })

      assert unchanged.status == "read"
    end

    test "returns error for unknown provider_message_id", %{channel: channel} do
      assert {:error, :delivery_not_found} =
               Deliveries.apply_status_update(channel.id, %{
                 "provider_message_id" => "unknown-id",
                 "status" => "delivered"
               })
    end

    test "looks up by delivery_id", %{delivery: delivery, channel: channel} do
      {:ok, sent} = Deliveries.mark_sent(delivery)

      assert {:ok, updated} =
               Deliveries.apply_status_update(channel.id, %{
                 "delivery_id" => sent.id,
                 "status" => "delivered"
               })

      assert updated.status == "delivered"
    end

    test "returns error when missing identifier", %{channel: channel} do
      assert {:error, :missing_identifier} =
               Deliveries.apply_status_update(channel.id, %{"status" => "delivered"})
    end

    test "parses ISO8601 timestamp", %{delivery: delivery, channel: channel} do
      {:ok, _} = Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.123"})

      {:ok, updated} =
        Deliveries.apply_status_update(channel.id, %{
          "provider_message_id" => "wamid.123",
          "status" => "delivered",
          "timestamp" => "2026-02-27T12:00:00Z"
        })

      assert DateTime.truncate(updated.delivered_at, :second) == ~U[2026-02-27 12:00:00Z]
    end

    test "parses Unix timestamp", %{delivery: delivery, channel: channel} do
      {:ok, _} = Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.123"})

      {:ok, updated} =
        Deliveries.apply_status_update(channel.id, %{
          "provider_message_id" => "wamid.123",
          "status" => "delivered",
          "timestamp" => "1740657600"
        })

      assert updated.delivered_at != nil
    end
  end

  describe "get_delivery_by_provider_message_id/2" do
    test "finds delivery by provider message ID", %{delivery: delivery, channel: channel} do
      {:ok, _} = Deliveries.mark_sent(delivery, %{whatsapp_message_id: "wamid.lookup"})

      found = Deliveries.get_delivery_by_provider_message_id(channel.id, "wamid.lookup")
      assert found.id == delivery.id
    end

    test "returns nil for non-existent provider message ID", %{channel: channel} do
      assert nil == Deliveries.get_delivery_by_provider_message_id(channel.id, "non-existent")
    end
  end

  describe "list_deliveries_for_activities/1" do
    test "returns deliveries for given activity IDs", %{activity: activity, delivery: delivery} do
      results = Deliveries.list_deliveries_for_activities([activity.id])
      assert length(results) == 1
      assert hd(results).id == delivery.id
    end

    test "returns empty list for empty input" do
      assert [] == Deliveries.list_deliveries_for_activities([])
    end
  end

  describe "count_by_status/0" do
    test "returns counts grouped by status", %{delivery: delivery} do
      {:ok, _} = Deliveries.mark_sent(delivery)
      counts = Deliveries.count_by_status()
      assert Map.get(counts, "sent", 0) >= 1
    end
  end

  describe "status_rank/1" do
    test "returns correct rank ordering" do
      assert Delivery.status_rank("pending") == 0
      assert Delivery.status_rank("sent") == 1
      assert Delivery.status_rank("delivered") == 2
      assert Delivery.status_rank("read") == 3
      assert Delivery.status_rank("failed") == -1
    end
  end
end
