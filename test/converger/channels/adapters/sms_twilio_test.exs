defmodule Converger.Channels.Adapters.SmsTwilioTest do
  use Converger.DataCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.Channels
  alias Converger.Channels.Adapters.SmsTwilio
  alias Converger.Channels.DeliveryError
  alias Converger.Participants

  @config %{"account_sid" => "AC123", "auth_token" => "token", "from" => "+15005550006"}

  setup do
    Application.put_env(:converger, :sms_req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.delete_env(:converger, :sms_req_options) end)
    :ok
  end

  defp stub(status, body) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:form, raw |> URI.query_decoder() |> Enum.to_list()})
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  defp activity(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        conversation_id: nil,
        text: "hi",
        attachments: [],
        metadata: %{}
      },
      attrs
    )
  end

  defp channel(config \\ %{}), do: %{id: Ecto.UUID.generate(), config: Map.merge(@config, config)}

  describe "validate_config/1" do
    test "needs an AC account SID and a sender" do
      assert SmsTwilio.validate_config(@config) == :ok
      assert {:error, _} = SmsTwilio.validate_config(%{@config | "account_sid" => "XX1"})

      assert {:error, msg} = SmsTwilio.validate_config(Map.delete(@config, "from"))
      assert msg =~ "messaging_service_sid"

      assert :ok =
               @config
               |> Map.delete("from")
               |> Map.put("messaging_service_sid", "MG1")
               |> SmsTwilio.validate_config()
    end

    test "is wired into channel creation" do
      tenant = tenant_fixture()

      assert {:error, changeset} =
               Channels.create_channel(%{
                 name: unique_channel_name(),
                 type: "sms_twilio",
                 mode: "duplex",
                 tenant_id: tenant.id,
                 config: %{"account_sid" => "AC1"}
               })

      assert inspect(changeset.errors) =~ "auth_token"
    end
  end

  describe "deliver_activity/2" do
    test "sends through a messaging service with MMS media" do
      stub(201, %{"sid" => "SM1", "num_segments" => "1"})

      channel = channel(%{"messaging_service_sid" => "MG1"})

      activity =
        activity(%{
          metadata: %{"to" => "+1 415 555 0100"},
          attachments: [
            %{"contentType" => "image/png", "contentUrl" => "https://cdn.example.com/a.png"},
            %{"contentType" => "image/png", "contentUrl" => "/api/v1/converger/attachments/x"}
          ]
        })

      assert {:ok, %{provider_message_id: "SM1", sms_segments: 1}} =
               SmsTwilio.deliver_activity(channel, activity)

      assert_received {:form, form}
      assert {"To", "+14155550100"} in form
      assert {"MessagingServiceSid", "MG1"} in form
      refute List.keymember?(form, "From", 0)

      assert [{"MediaUrl", "https://cdn.example.com/a.png"}] =
               Enum.filter(form, &(elem(&1, 0) == "MediaUrl"))
    end

    test "a text over max_segments is a permanent error" do
      channel = channel(%{"max_segments" => 1})

      activity =
        activity(%{metadata: %{"to" => "+14155550100"}, text: String.duplicate("a", 161)})

      assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
               SmsTwilio.deliver_activity(channel, activity)

      assert reason =~ "segments"
      refute_received {:form, _}
    end

    test "no recipient or an invalid one is a permanent error" do
      assert {:error, %DeliveryError{retryable?: false}} =
               SmsTwilio.deliver_activity(channel(), activity(%{}))

      assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
               SmsTwilio.deliver_activity(channel(), activity(%{metadata: %{"to" => "ACME"}}))

      assert reason =~ "E.164"
    end

    test "Twilio error 21610 opts the recipient out" do
      tenant = tenant_fixture()

      {:ok, channel} =
        Channels.create_channel(%{
          name: unique_channel_name(),
          type: "sms_twilio",
          mode: "duplex",
          tenant_id: tenant.id,
          config: @config
        })

      stub(400, %{"code" => 21_610, "message" => "Attempt to send to unsubscribed recipient"})
      activity = activity(%{metadata: %{"to" => "+14155550100"}})

      assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
               SmsTwilio.deliver_activity(channel, activity)

      assert reason =~ "opted out"
      assert Participants.opted_out?(channel.id, "+14155550100")
    end

    test "429 and 5xx are retryable" do
      stub(429, %{"code" => 20_429})
      activity = activity(%{metadata: %{"to" => "+14155550100"}})

      assert {:error, %DeliveryError{retryable?: true}} =
               SmsTwilio.deliver_activity(channel(), activity)
    end
  end

  describe "parse_inbound/2 and parse_status_update/2" do
    test "a status callback is not a message" do
      params = %{"MessageSid" => "SM1", "From" => "+1", "MessageStatus" => "delivered"}
      assert SmsTwilio.parse_inbound(channel(), params) == {:ok, []}

      assert {:ok, [%{"provider_message_id" => "SM1", "status" => "delivered"}]} =
               SmsTwilio.parse_status_update(channel(), params)
    end

    test "maps Twilio statuses" do
      for {twilio, ours} <- [
            {"sent", "sent"},
            {"delivered", "delivered"},
            {"read", "read"},
            {"undelivered", "failed"},
            {"failed", "failed"},
            {"canceled", "failed"}
          ] do
        params = %{"MessageSid" => "SM1", "MessageStatus" => twilio}
        assert {:ok, [%{"status" => ^ours}]} = SmsTwilio.parse_status_update(channel(), params)
      end

      for status <- ~w(queued accepted sending scheduled) do
        params = %{"MessageSid" => "SM1", "MessageStatus" => status}
        assert SmsTwilio.parse_status_update(channel(), params) == {:ok, []}
      end
    end

    test "a failed status carries the error code" do
      params = %{
        "MessageSid" => "SM1",
        "MessageStatus" => "undelivered",
        "ErrorCode" => "30003",
        "ErrorMessage" => "Unreachable destination handset"
      }

      assert {:ok, [%{"error" => "Twilio error 30003: Unreachable destination handset"}]} =
               SmsTwilio.parse_status_update(channel(), params)
    end

    test "an inbound message with a national number and a default country code" do
      params = %{"MessageSid" => "SM9", "From" => "05321234567", "Body" => "merhaba"}
      channel = channel(%{"default_country_code" => "90"})

      assert {:ok,
              [
                %{
                  "sender" => "+905321234567",
                  "participant" => %{"external_id" => "+905321234567"}
                }
              ]} =
               SmsTwilio.parse_inbound(channel, params)
    end

    test "Twilio's OptOutType wins over the text" do
      params = %{
        "MessageSid" => "SM9",
        "From" => "+14155550100",
        "Body" => "arrêt",
        "OptOutType" => "STOP"
      }

      assert {:ok, [%{"type" => "event", "opt_out" => "stop"}]} =
               SmsTwilio.parse_inbound(channel(), params)
    end

    test "rejects a payload that is not a Twilio webhook" do
      assert {:error, _} = SmsTwilio.parse_inbound(channel(), %{"foo" => "bar"})
    end
  end

  describe "verify_inbound_signature/3" do
    defp sign(url, body) do
      data =
        body |> URI.query_decoder() |> Enum.sort() |> Enum.map_join(fn {k, v} -> k <> v end)

      Base.encode64(:crypto.mac(:hmac, :sha, "token", url <> data))
    end

    test "accepts a signature over the webhook_base_url" do
      channel = channel(%{"webhook_base_url" => "https://sms.example.com/"})
      body = "Body=hi+there&From=%2B14155550100&MessageSid=SM1"
      url = "https://sms.example.com/api/v1/channels/#{channel.id}/inbound"

      assert SmsTwilio.verify_inbound_signature(
               channel,
               [{"x-twilio-signature", sign(url, body)}],
               body
             ) == :ok
    end

    test "accepts a signature over the request host behind a proxy" do
      channel = channel()
      body = "MessageSid=SM1&MessageStatus=delivered"
      url = "http://proxy.internal:8080/api/v1/channels/#{channel.id}/status"

      headers = [
        {"host", "proxy.internal:8080"},
        {"x-forwarded-proto", "http"},
        {"x-twilio-signature", sign(url, body)}
      ]

      assert SmsTwilio.verify_inbound_signature(channel, headers, body) == :ok
    end

    test "rejects a signature for another channel or a tampered body" do
      channel = channel()
      body = "MessageSid=SM1&Body=hi"
      other = "#{ConvergerWeb.Endpoint.url()}/api/v1/channels/#{Ecto.UUID.generate()}/inbound"

      assert SmsTwilio.verify_inbound_signature(
               channel,
               [{"x-twilio-signature", sign(other, body)}],
               body
             ) == {:error, :invalid_signature}

      url = "#{ConvergerWeb.Endpoint.url()}/api/v1/channels/#{channel.id}/inbound"

      assert SmsTwilio.verify_inbound_signature(
               channel,
               [{"x-twilio-signature", sign(url, body)}],
               body <> "x"
             ) == {:error, :invalid_signature}
    end

    test "missing header or auth token" do
      assert SmsTwilio.verify_inbound_signature(channel(), [], "") == :missing

      assert SmsTwilio.verify_inbound_signature(
               channel(%{"auth_token" => ""}),
               [{"x-twilio-signature", "x"}],
               ""
             ) == :missing
    end
  end
end
