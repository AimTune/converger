defmodule ConvergerWeb.InboundBatchTest do
  use ConvergerWeb.ConnCase

  import ExUnit.CaptureLog
  import Ecto.Query
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.Activities.Activity
  alias Converger.Channels
  alias Converger.Channels.InboundSignature
  alias Converger.Conversations.Conversation
  alias Converger.Repo

  @app_secret "meta-app-secret-batch"

  setup do
    tenant = tenant_fixture()

    {:ok, meta} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "whatsapp_meta",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "phone_number_id" => "106540352242922",
          "access_token" => "token",
          "verify_token" => "verify",
          "app_secret" => @app_secret
        }
      })

    %{tenant: tenant, meta: meta}
  end

  defp meta_post(conn, channel, params) do
    body = Jason.encode!(params)
    signature = "sha256=" <> InboundSignature.hmac_hex(@app_secret, body)

    # Inline pipeline tries to deliver the inbound message back to WhatsApp
    # (no recipient metadata, so it fails without network I/O); keep the log quiet.
    {conn, _log} =
      with_log(fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", signature)
        |> post(~p"/api/v1/channels/#{channel.id}/inbound", body)
      end)

    conn
  end

  defp activities_for_channel(channel) do
    from(a in Activity,
      join: c in Conversation,
      on: c.id == a.conversation_id,
      where: c.channel_id == ^channel.id,
      order_by: [asc: a.inserted_at, asc: a.seq]
    )
    |> Repo.all()
  end

  defp text_message(id, body, from \\ "16505551234") do
    %{
      "from" => from,
      "id" => id,
      "timestamp" => "1749416383",
      "type" => "text",
      "text" => %{"body" => body}
    }
  end

  defp meta_webhook(messages, statuses \\ []) do
    value =
      %{
        "messaging_product" => "whatsapp",
        "metadata" => %{"phone_number_id" => "106540352242922"},
        "contacts" => [%{"profile" => %{"name" => "Sheena"}, "wa_id" => "16505551234"}],
        "messages" => messages
      }
      |> then(fn v -> if statuses == [], do: v, else: Map.put(v, "statuses", statuses) end)

    %{
      "object" => "whatsapp_business_account",
      "entry" => [%{"id" => "1", "changes" => [%{"field" => "messages", "value" => value}]}]
    }
  end

  @three_messages [
    %{"id" => "wamid.batch-1", "body" => "first"},
    %{"id" => "wamid.batch-2", "body" => "second"},
    %{"id" => "wamid.batch-3", "body" => "third"}
  ]

  defp three_message_webhook do
    @three_messages
    |> Enum.map(&text_message(&1["id"], &1["body"]))
    |> meta_webhook()
  end

  describe "WhatsApp Meta batches" do
    test "a webhook with 3 messages creates 3 activities", %{conn: conn, meta: meta} do
      conn = meta_post(conn, meta, three_message_webhook())

      body = json_response(conn, 200)
      assert body["status"] == "accepted"
      assert length(body["activity_ids"]) == 3
      assert body["duplicates"] == 0

      activities = activities_for_channel(meta)
      assert Enum.map(activities, & &1.text) == ["first", "second", "third"]

      assert Enum.map(activities, & &1.idempotency_key) ==
               ["wamid.batch-1", "wamid.batch-2", "wamid.batch-3"]

      assert Enum.all?(activities, &(&1.sender == "16505551234"))
    end

    test "a re-delivered webhook creates no duplicates", %{conn: conn, meta: meta} do
      first = meta_post(conn, meta, three_message_webhook())
      first_ids = json_response(first, 200)["activity_ids"]

      again = meta_post(build_conn(), meta, three_message_webhook())
      body = json_response(again, 200)

      assert body["duplicates"] == 3
      assert body["activity_ids"] == first_ids
      assert length(activities_for_channel(meta)) == 3
    end

    test "a partially processed batch is completed on re-delivery", %{conn: conn, meta: meta} do
      meta_post(conn, meta, meta_webhook([text_message("wamid.batch-1", "first")]))

      body = json_response(meta_post(build_conn(), meta, three_message_webhook()), 200)

      assert body["duplicates"] == 1
      assert length(body["activity_ids"]) == 3
      assert length(activities_for_channel(meta)) == 3
    end

    test "an image message creates an activity with an attachment stub", %{
      conn: conn,
      meta: meta
    } do
      image = %{
        "from" => "16505551234",
        "id" => "wamid.image-1",
        "timestamp" => "1749416383",
        "type" => "image",
        "image" => %{"mime_type" => "image/jpeg", "sha256" => "abc", "id" => "media-42"}
      }

      conn = meta_post(conn, meta, meta_webhook([image]))
      assert [_id] = json_response(conn, 200)["activity_ids"]

      assert [activity] = activities_for_channel(meta)

      assert [
               %{
                 "contentType" => "image/jpeg",
                 "channelData" => %{"providerMediaId" => "media-42"}
               }
             ] =
               activity.attachments

      assert activity.metadata["whatsapp_type"] == "image"
    end

    test "a permanently invalid message is skipped and acknowledged", %{conn: conn, meta: meta} do
      too_long = String.duplicate("x", Activity.limits()[:max_text_bytes] + 1)

      webhook =
        meta_webhook([text_message("wamid.ok-1", "ok"), text_message("wamid.bad", too_long)])

      body = json_response(meta_post(conn, meta, webhook), 200)

      assert body["rejected"] == 1
      assert length(body["activity_ids"]) == 1
      assert [%{text: "ok"}] = activities_for_channel(meta)
    end

    test "a webhook without messages or statuses is acknowledged", %{conn: conn, meta: meta} do
      webhook = %{
        "object" => "whatsapp_business_account",
        "entry" => [%{"id" => "1", "changes" => [%{"field" => "account_update", "value" => %{}}]}]
      }

      assert json_response(meta_post(conn, meta, webhook), 200)["status"] == "accepted"
      assert activities_for_channel(meta) == []
    end

    test "messages and statuses in the same webhook are both processed", %{
      conn: conn,
      meta: meta
    } do
      status = %{
        "id" => "wamid.unknown-outbound",
        "status" => "delivered",
        "timestamp" => "1709035200",
        "recipient_id" => "16505551234"
      }

      webhook = meta_webhook([text_message("wamid.mixed-1", "hello")], [status])
      body = json_response(meta_post(conn, meta, webhook), 200)

      assert [_] = body["activity_ids"]
      assert body["receipts_processed"] == 0
      assert [%{text: "hello"}] = activities_for_channel(meta)
    end
  end

  defp infobip_result(id, text) do
    %{
      "from" => "5511999999999",
      "to" => "447860099299",
      "integrationType" => "WHATSAPP",
      "receivedAt" => "2026-02-27T12:00:00.000+0000",
      "messageId" => id,
      "message" => %{"type" => "TEXT", "text" => text},
      "contact" => %{"name" => "Frank"}
    }
  end

  describe "WhatsApp Infobip batches" do
    setup %{tenant: tenant} do
      {:ok, infobip} =
        Channels.create_channel(%{
          name: unique_channel_name(),
          type: "whatsapp_infobip",
          mode: "inbound",
          status: "active",
          tenant_id: tenant.id,
          config: %{
            "base_url" => "https://example.api.infobip.com",
            "api_key" => "key",
            "sender" => "447860099299"
          }
        })

      %{infobip: infobip}
    end

    test "3 results create 3 activities and re-delivery creates none", %{
      conn: conn,
      infobip: infobip
    } do
      params = %{
        "results" => [
          infobip_result("ib-1", "one"),
          infobip_result("ib-2", "two"),
          infobip_result("ib-3", "three")
        ],
        "messageCount" => 3,
        "pendingMessageCount" => 0
      }

      path = ~p"/api/v1/channels/#{infobip.id}/inbound"

      assert [_, _, _] =
               json_response(signed_post(conn, path, infobip, params), 200)["activity_ids"]

      assert json_response(signed_post(build_conn(), path, infobip, params), 200)["duplicates"] ==
               3

      assert Enum.map(activities_for_channel(infobip), & &1.text) == ["one", "two", "three"]
    end
  end

  describe "generic webhook" do
    test "idempotency_key de-duplicates re-delivered messages", %{conn: conn, tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "inbound"})
      path = ~p"/api/v1/channels/#{channel.id}/inbound"
      params = %{"text" => "hello", "sender" => "user1", "idempotency_key" => "evt-1"}

      first = json_response(signed_post(conn, path, channel, params), 201)
      again = json_response(signed_post(build_conn(), path, channel, params), 200)

      assert again["activity_id"] == first["activity_id"]
      assert again["duplicates"] == 1
      assert length(activities_for_channel(channel)) == 1
    end

    test "an invalid single message is still rejected with 422", %{conn: conn, tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "inbound"})

      conn =
        signed_post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", channel, %{
          "text" => "hello",
          "sender" => "user1",
          "type" => "not-a-type"
        })

      assert json_response(conn, 422)
    end
  end
end
