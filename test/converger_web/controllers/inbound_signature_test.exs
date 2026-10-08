defmodule ConvergerWeb.InboundSignatureTest do
  use ConvergerWeb.ConnCase

  import ExUnit.CaptureLog
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.Channels
  alias Converger.Channels.InboundSignature

  @meta_app_secret "meta-app-secret-fixture"

  # Raw body exactly as Meta delivers it; the signature covers these bytes.
  @meta_message_fixture ~s({"object":"whatsapp_business_account","entry":[{"id":"102290129340398","changes":[{"value":{"messaging_product":"whatsapp","metadata":{"display_phone_number":"15550783881","phone_number_id":"106540352242922"},"contacts":[{"profile":{"name":"Sheena Nelson"},"wa_id":"16505551234"}],"messages":[{"from":"16505551234","id":"wamid.HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRBNjU5OUFFRTAzODEwMTQ0RgA=","timestamp":"1749416383","type":"text","text":{"body":"Does it come in another color?"}}]},"field":"messages"}]}]})

  setup do
    %{tenant: tenant_fixture()}
  end

  defp raw_post(conn, path, body, headers) do
    headers
    |> Enum.reduce(put_req_header(conn, "content-type", "application/json"), fn {k, v}, acc ->
      put_req_header(acc, k, v)
    end)
    |> post(path, body)
  end

  describe "generic x-converger-signature" do
    test "new channels require signatures by default", %{tenant: tenant} do
      assert webhook_channel_fixture(tenant).require_signature == true
    end

    test "unsigned /inbound to a require_signature channel returns 401", %{
      conn: conn,
      tenant: tenant
    } do
      channel = webhook_channel_fixture(tenant)

      conn =
        post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", %{
          "text" => "hello",
          "sender" => "user1"
        })

      assert json_response(conn, 401)
    end

    test "unsigned /status to a require_signature channel returns 401", %{
      conn: conn,
      tenant: tenant
    } do
      channel = webhook_channel_fixture(tenant)

      conn =
        post(conn, ~p"/api/v1/channels/#{channel.id}/status", %{
          "provider_message_id" => "x",
          "status" => "delivered"
        })

      assert json_response(conn, 401)
    end

    test "tampered body on /status returns 401", %{conn: conn, tenant: tenant} do
      channel = webhook_channel_fixture(tenant)
      signed = Jason.encode!(%{"provider_message_id" => "x", "status" => "delivered"})
      tampered = Jason.encode!(%{"provider_message_id" => "x", "status" => "read"})

      conn =
        raw_post(conn, ~p"/api/v1/channels/#{channel.id}/status", tampered, [
          {"x-converger-signature", InboundSignature.sign(channel.secret, signed)}
        ])

      assert json_response(conn, 401)
    end

    test "tampered body on /status returns 401 even when signatures are optional", %{
      conn: conn,
      tenant: tenant
    } do
      channel = webhook_channel_fixture(tenant, %{require_signature: false})
      signed = Jason.encode!(%{"provider_message_id" => "x", "status" => "delivered"})
      tampered = Jason.encode!(%{"provider_message_id" => "x", "status" => "read"})

      capture_log(fn ->
        conn =
          raw_post(conn, ~p"/api/v1/channels/#{channel.id}/status", tampered, [
            {"x-converger-signature", InboundSignature.sign(channel.secret, signed)}
          ])

        assert json_response(conn, 401)
      end)
    end

    test "valid signature on /status is accepted", %{conn: conn, tenant: tenant} do
      channel = webhook_channel_fixture(tenant)

      conn =
        signed_post(conn, ~p"/api/v1/channels/#{channel.id}/status", channel, %{
          "provider_message_id" => "x",
          "status" => "delivered"
        })

      assert json_response(conn, 200)["status"] == "accepted"
    end

    test "signature signed with another secret returns 401", %{conn: conn, tenant: tenant} do
      channel = webhook_channel_fixture(tenant)
      body = Jason.encode!(%{"text" => "hello", "sender" => "user1"})

      conn =
        raw_post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", body, [
          {"x-converger-signature", InboundSignature.sign("wrong-secret", body)}
        ])

      assert json_response(conn, 401)
    end

    test "timestamp outside the tolerance window returns 401", %{conn: conn, tenant: tenant} do
      channel = webhook_channel_fixture(tenant)
      stale = System.system_time(:second) - InboundSignature.tolerance_seconds() - 1

      conn =
        signed_post(
          conn,
          ~p"/api/v1/channels/#{channel.id}/inbound",
          channel,
          %{"text" => "hello", "sender" => "user1"},
          timestamp: stale
        )

      assert json_response(conn, 401)
    end

    test "malformed signature header returns 401", %{conn: conn, tenant: tenant} do
      channel = webhook_channel_fixture(tenant)
      body = Jason.encode!(%{"text" => "hello", "sender" => "user1"})

      conn =
        raw_post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", body, [
          {"x-converger-signature", "garbage"}
        ])

      assert json_response(conn, 401)
    end

    test "legacy sha256= signature is rejected when signatures are required", %{
      conn: conn,
      tenant: tenant
    } do
      channel = webhook_channel_fixture(tenant)
      body = Jason.encode!(%{"text" => "hello", "sender" => "user1"})

      conn =
        raw_post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", body, [
          {"x-converger-signature", InboundSignature.sign_legacy(channel.secret, body)}
        ])

      assert json_response(conn, 401)
    end
  end

  describe "channels with require_signature: false (legacy)" do
    test "unsigned request is accepted with a deprecation warning", %{
      conn: conn,
      tenant: tenant
    } do
      channel = webhook_channel_fixture(tenant, %{require_signature: false})

      log =
        capture_log(fn ->
          conn =
            post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", %{
              "text" => "hello",
              "sender" => "user1"
            })

          assert json_response(conn, 201)["status"] == "accepted"
        end)

      assert log =~ "DEPRECATED"
    end

    test "legacy sha256= signature is accepted with a deprecation warning", %{
      conn: conn,
      tenant: tenant
    } do
      channel = webhook_channel_fixture(tenant, %{require_signature: false})
      body = Jason.encode!(%{"text" => "hello", "sender" => "user1"})

      log =
        capture_log(fn ->
          conn =
            raw_post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", body, [
              {"x-converger-signature", InboundSignature.sign_legacy(channel.secret, body)}
            ])

          assert json_response(conn, 201)["status"] == "accepted"
        end)

      assert log =~ "legacy"
    end
  end

  describe "WhatsApp Meta X-Hub-Signature-256" do
    setup %{tenant: tenant} do
      {:ok, channel} =
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
            "app_secret" => @meta_app_secret
          }
        })

      %{channel: channel}
    end

    test "valid signature on the fixture payload is accepted", %{conn: conn, channel: channel} do
      signature = "sha256=" <> InboundSignature.hmac_hex(@meta_app_secret, @meta_message_fixture)

      conn =
        raw_post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", @meta_message_fixture, [
          {"x-hub-signature-256", signature}
        ])

      assert json_response(conn, 200)["status"] == "accepted"
    end

    test "invalid signature returns 401", %{conn: conn, channel: channel} do
      signature =
        "sha256=" <> InboundSignature.hmac_hex("not-the-app-secret", @meta_message_fixture)

      conn =
        raw_post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", @meta_message_fixture, [
          {"x-hub-signature-256", signature}
        ])

      assert json_response(conn, 401)
    end

    test "tampered fixture payload returns 401", %{conn: conn, channel: channel} do
      signature = "sha256=" <> InboundSignature.hmac_hex(@meta_app_secret, @meta_message_fixture)
      tampered = String.replace(@meta_message_fixture, "another color", "a discount")

      conn =
        raw_post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", tampered, [
          {"x-hub-signature-256", signature}
        ])

      assert json_response(conn, 401)
    end

    test "missing signature returns 401", %{conn: conn, channel: channel} do
      conn = raw_post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", @meta_message_fixture, [])

      assert json_response(conn, 401)
    end

    test "generic x-converger-signature is not accepted in place of Meta's", %{
      conn: conn,
      channel: channel
    } do
      conn =
        raw_post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", @meta_message_fixture, [
          {"x-converger-signature", InboundSignature.sign(channel.secret, @meta_message_fixture)}
        ])

      assert json_response(conn, 401)
    end

    test "app_secret is required when require_signature is true", %{tenant: tenant} do
      assert {:error, changeset} =
               Channels.create_channel(%{
                 name: unique_channel_name(),
                 type: "whatsapp_meta",
                 status: "active",
                 tenant_id: tenant.id,
                 config: %{
                   "phone_number_id" => "1",
                   "access_token" => "token",
                   "verify_token" => "verify"
                 }
               })

      assert {msg, _} = changeset.errors[:config]
      assert msg =~ "app_secret"
    end
  end
end
