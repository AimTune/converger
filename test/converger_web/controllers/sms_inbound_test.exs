defmodule ConvergerWeb.SmsInboundTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.Activities.Activity
  alias Converger.Channels
  alias Converger.Conversations
  alias Converger.Deliveries.Delivery
  alias Converger.Participants
  alias Converger.Repo

  @auth_token "twilio-auth-token"
  @signature_secret "vonage-signature-secret"
  @phone "+14155550100"

  setup do
    Application.put_env(:converger, :sms_req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.delete_env(:converger, :sms_req_options) end)

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sms_request, conn.host, conn.request_path, body})

      case conn.host do
        "api.twilio.com" ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "sid" => "SM-out-#{System.unique_integer([:positive])}",
            "status" => "queued",
            "num_segments" => "1"
          })

        "api.nexmo.com" ->
          conn
          |> Plug.Conn.put_status(202)
          |> Req.Test.json(%{"message_uuid" => "uuid-out-#{System.unique_integer([:positive])}"})
      end
    end)

    tenant = tenant_fixture()
    %{tenant: tenant}
  end

  defp channel(tenant, type, config) do
    {:ok, channel} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: type,
        mode: "duplex",
        status: "active",
        require_signature: true,
        tenant_id: tenant.id,
        config: config
      })

    channel
  end

  defp twilio_channel(tenant) do
    channel(tenant, "sms_twilio", %{
      "account_sid" => "AC123",
      "auth_token" => @auth_token,
      "from" => "+15005550006"
    })
  end

  defp vonage_channel(tenant) do
    channel(tenant, "sms_vonage", %{
      "api_key" => "key",
      "api_secret" => "secret",
      "from" => "15005550006",
      "signature_secret" => @signature_secret
    })
  end

  defp twilio_post(channel, endpoint, params) do
    path = "/api/v1/channels/#{channel.id}/#{endpoint}"
    url = ConvergerWeb.Endpoint.url() <> path
    data = params |> Enum.sort() |> Enum.map_join(fn {k, v} -> k <> v end)
    signature = Base.encode64(:crypto.mac(:hmac, :sha, @auth_token, url <> data))

    build_conn()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("x-twilio-signature", signature)
    |> post(path, URI.encode_query(params))
  end

  defp twilio_sms(channel, sid, text, extra \\ %{}) do
    params =
      Map.merge(
        %{
          "MessageSid" => sid,
          "SmsStatus" => "received",
          "From" => @phone,
          "To" => "+15005550006",
          "Body" => text,
          "NumMedia" => "0",
          "NumSegments" => "1"
        },
        extra
      )

    conn = twilio_post(channel, "inbound", params)
    assert response(conn, 200) =~ "<Response>"
    assert response_content_type(conn, :xml)
    conn
  end

  defp vonage_post(channel, endpoint, params, secret \\ @signature_secret) do
    body = Jason.encode!(params)
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    {:ok, token, _} =
      Joken.encode_and_sign(
        %{"iss" => "Vonage", "iat" => System.system_time(:second), "payload_hash" => hash},
        Joken.Signer.create("HS256", secret)
      )

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/api/v1/channels/#{channel.id}/#{endpoint}", body)
  end

  defp reply(tenant, conversation_id, text) do
    conn =
      build_conn()
      |> put_req_header("x-api-key", tenant.api_key)
      |> post(~p"/api/v1/conversations/#{conversation_id}/activities", %{
        "type" => "message",
        "text" => text,
        "sender" => "agent"
      })

    Repo.get!(Activity, json_response(conn, 201)["id"] || json_response(conn, 201)["data"]["id"])
  end

  defp delivery(activity, channel),
    do: Repo.get_by!(Delivery, activity_id: activity.id, channel_id: channel.id)

  describe "Twilio" do
    test "inbound SMS creates a participant conversation; the reply's DLR marks it delivered",
         %{tenant: tenant} do
      channel = twilio_channel(tenant)
      twilio_sms(channel, "SM-in-1", "hello")

      [activity] = Repo.all(Activity)
      assert activity.sender == @phone
      assert activity.metadata["sms_segments"] == 1
      assert activity.idempotency_key == "SM-in-1"

      conversation =
        activity.conversation_id
        |> Conversations.get_conversation!()
        |> Repo.preload(:participant)

      assert conversation.participant.external_id == @phone
      assert conversation.participant.channel_id == channel.id
      refute_received {:sms_request, _, _, _}

      reply = reply(tenant, activity.conversation_id, "hi there")

      assert_received {:sms_request, "api.twilio.com", "/2010-04-01/Accounts/AC123/Messages.json",
                       body}

      form = URI.decode_query(body)
      assert form["To"] == @phone
      assert form["From"] == "+15005550006"
      assert form["Body"] == "hi there"
      assert form["StatusCallback"] =~ "/api/v1/channels/#{channel.id}/status"

      sent = delivery(reply, channel)
      assert sent.status == "sent"
      assert "SM-out-" <> _ = sent.provider_message_id

      conn =
        twilio_post(channel, "status", %{
          "MessageSid" => sent.provider_message_id,
          "MessageStatus" => "delivered",
          "SmsStatus" => "delivered",
          "To" => @phone
        })

      assert response(conn, 200)
      assert delivery(reply, channel).status == "delivered"
    end

    test "STOP opts the participant out; later deliveries fail fast; START opts back in",
         %{tenant: tenant} do
      channel = twilio_channel(tenant)
      twilio_sms(channel, "SM-in-2", "hello")
      twilio_sms(channel, "SM-in-3", "STOP", %{"OptOutType" => "STOP"})

      stop = Repo.get_by!(Activity, idempotency_key: "SM-in-3")
      assert stop.type == "event"
      assert stop.metadata["smsOptOut"] == "stop"
      assert Participants.opted_out?(channel.id, @phone)

      reply = reply(tenant, stop.conversation_id, "are you there?")
      refute_received {:sms_request, _, _, _}

      failed = delivery(reply, channel)
      assert failed.status == "failed"
      assert failed.last_error =~ "opted out"

      twilio_sms(channel, "SM-in-4", "start")
      refute Participants.opted_out?(channel.id, @phone)

      reply(tenant, stop.conversation_id, "welcome back")
      assert_received {:sms_request, "api.twilio.com", _, _}
    end

    test "a re-delivered STOP is a duplicate and keeps the participant opted out",
         %{tenant: tenant} do
      channel = twilio_channel(tenant)
      twilio_sms(channel, "SM-in-5", "stop")
      twilio_sms(channel, "SM-in-5", "stop")

      assert Repo.aggregate(Activity, :count) == 1
      assert Participants.opted_out?(channel.id, @phone)
    end

    test "MMS media become attachments", %{tenant: tenant} do
      channel = twilio_channel(tenant)

      twilio_sms(channel, "SM-in-6", "look", %{
        "NumMedia" => "1",
        "MediaUrl0" => "https://api.twilio.com/2010-04-01/Accounts/AC123/Messages/MM1/Media/ME1",
        "MediaContentType0" => "image/jpeg"
      })

      [activity] = Repo.all(Activity)

      assert [%{"contentType" => "image/jpeg", "contentUrl" => "https://api.twilio.com/" <> _}] =
               activity.attachments
    end

    test "an intermediate status callback is acknowledged with TwiML", %{tenant: tenant} do
      channel = twilio_channel(tenant)

      conn =
        twilio_post(channel, "status", %{
          "MessageSid" => "SM-unknown",
          "MessageStatus" => "queued"
        })

      assert response(conn, 200) =~ "<Response>"
    end

    test "a bad signature is rejected", %{tenant: tenant} do
      channel = twilio_channel(tenant)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("x-twilio-signature", "bm9wZQ==")
        |> post("/api/v1/channels/#{channel.id}/inbound", "MessageSid=SM1&From=%2B1&Body=x")

      assert response(conn, 401)
      assert Repo.aggregate(Activity, :count) == 0
    end
  end

  describe "Vonage" do
    test "inbound SMS, reply and DLR", %{tenant: tenant} do
      channel = vonage_channel(tenant)

      conn =
        vonage_post(channel, "inbound", %{
          "channel" => "sms",
          "message_uuid" => "uuid-in-1",
          "message_type" => "text",
          "from" => "14155550100",
          "to" => "15005550006",
          "text" => "hello",
          "timestamp" => "2026-10-12T10:00:00Z",
          "sms" => %{"num_messages" => "1"}
        })

      assert json_response(conn, 200)
      [activity] = Repo.all(Activity)
      assert activity.sender == @phone
      assert activity.metadata["sms_segments"] == 1

      reply = reply(tenant, activity.conversation_id, "hi there")
      assert_received {:sms_request, "api.nexmo.com", "/v1/messages", body}
      payload = Jason.decode!(body)
      assert payload["to"] == "14155550100"
      assert payload["channel"] == "sms"
      assert payload["client_ref"] == reply.id

      sent = delivery(reply, channel)
      assert sent.status == "sent"

      conn =
        vonage_post(channel, "status", %{
          "message_uuid" => sent.provider_message_id,
          "to" => "14155550100",
          "from" => "15005550006",
          "timestamp" => "2026-10-12T10:00:05Z",
          "status" => "delivered",
          "channel" => "sms"
        })

      assert json_response(conn, 200)["receipts_processed"] == 1
      assert delivery(reply, channel).status == "delivered"
    end

    test "STOP opts the participant out", %{tenant: tenant} do
      channel = vonage_channel(tenant)

      vonage_post(channel, "inbound", %{
        "channel" => "sms",
        "message_uuid" => "uuid-in-2",
        "from" => "14155550100",
        "text" => " Stop "
      })

      assert Participants.opted_out?(channel.id, @phone)
      [stop] = Repo.all(Activity)
      assert stop.type == "event"

      reply = reply(tenant, stop.conversation_id, "anyone?")
      refute_received {:sms_request, _, _, _}
      assert delivery(reply, channel).status == "failed"
    end

    test "a JWT signed with another secret is rejected", %{tenant: tenant} do
      channel = vonage_channel(tenant)

      conn =
        vonage_post(
          channel,
          "inbound",
          %{"channel" => "sms", "message_uuid" => "uuid-in-3", "from" => "1", "text" => "x"},
          "wrong-secret"
        )

      assert response(conn, 401)
    end
  end
end
