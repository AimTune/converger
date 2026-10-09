defmodule ConvergerWeb.SecurityReviewTest do
  @moduledoc """
  Regression tests for the findings of the security review done while
  writing the documentation site (tenant API token confusion, routing-rule
  tenant move, unscoped delivery status updates, cross-channel conversation
  access, SSRF on server-side URLs).
  """
  use ConvergerWeb.ConnCase, async: true

  require Phoenix.ChannelTest
  import Phoenix.ChannelTest, only: [subscribe_and_join: 3]

  alias Converger.Auth.{ConvergerToken, Token}
  alias Converger.{Channels, Deliveries, RoutingRules, Tenants}
  alias Converger.Channels.Adapters.WhatsAppInfobip
  alias Converger.Channels.DeliveryError
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  @endpoint ConvergerWeb.Endpoint

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp tenant_api(conn, token, conversation) do
    conn
    |> put_req_header("x-channel-token", token)
    |> get(~p"/api/v1/conversations/#{conversation.id}/activities")
  end

  describe "tenant API only accepts channel tokens" do
    test "a channel token is a tenant credential", %{conn: conn} = ctx do
      {:ok, token, _} = Token.generate_channel_token(ctx.channel)
      assert json_response(tenant_api(conn, token, ctx.conversation), 200)
    end

    test "a channel token issued before the `typ` claim still works", %{conn: conn} = ctx do
      {:ok, token, _} =
        Token.generate_and_sign(
          %{
            "channel_id" => ctx.channel.id,
            "tenant_id" => ctx.tenant.id,
            "sub" => "channel_#{ctx.channel.id}"
          },
          Converger.Auth.Signer.signer()
        )

      assert json_response(tenant_api(conn, token, ctx.conversation), 200)
    end

    test "an end-user conversation token is rejected", %{conn: conn} = ctx do
      {:ok, token, _} = Token.generate_token(ctx.conversation, ctx.tenant, "end-user")
      assert json_response(tenant_api(conn, token, ctx.conversation), 401)
    end

    test "a Converger client token is rejected", %{conn: conn} = ctx do
      {:ok, token, _} = ConvergerToken.generate_token(ctx.channel)
      assert json_response(tenant_api(conn, token, ctx.conversation), 401)

      {:ok, token, _} =
        ConvergerToken.generate_conversation_token(ctx.channel, ctx.conversation.id)

      assert json_response(tenant_api(conn, token, ctx.conversation), 401)
    end

    test "a channel token of a deactivated channel is rejected", %{conn: conn} = ctx do
      {:ok, token, _} = Token.generate_channel_token(ctx.channel)
      {:ok, _} = Channels.update_channel(ctx.channel, %{status: "inactive"})
      assert json_response(tenant_api(conn, token, ctx.conversation), 401)
    end
  end

  describe "routing rules" do
    test "an update cannot move a rule to another tenant", %{tenant: tenant} do
      source = webhook_channel_fixture(tenant)
      target = webhook_channel_fixture(tenant)

      {:ok, rule} =
        RoutingRules.create_routing_rule(%{
          "name" => "r1",
          "tenant_id" => tenant.id,
          "source_channel_id" => source.id,
          "target_channel_ids" => [target.id]
        })

      other = tenant_fixture()

      {:ok, updated} =
        RoutingRules.update_routing_rule(rule, %{"tenant_id" => other.id, "name" => "renamed"})

      assert updated.tenant_id == tenant.id
      assert updated.name == "renamed"
    end
  end

  describe "delivery status updates" do
    setup %{tenant: tenant, conversation: conversation} do
      channel = webhook_channel_fixture(tenant)
      activity = activity_fixture(tenant, conversation)
      delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)
      %{status_channel: channel, delivery: delivery}
    end

    test "are scoped to the reporting channel", %{tenant: tenant} = ctx do
      other_channel = webhook_channel_fixture(tenant)
      update = %{"delivery_id" => ctx.delivery.id, "status" => "delivered"}

      assert {:error, :delivery_not_found} =
               Deliveries.apply_status_update(other_channel.id, update)

      assert {:ok, %{status: "delivered"}} =
               Deliveries.apply_status_update(ctx.status_channel.id, update)
    end

    test "a malformed delivery id is not found, not an exception", ctx do
      assert {:error, :delivery_not_found} =
               Deliveries.apply_status_update(ctx.status_channel.id, %{
                 "delivery_id" => "not-a-uuid",
                 "status" => "delivered"
               })
    end
  end

  describe "Converger API tokens are bound to their channel" do
    setup %{tenant: tenant} do
      other_channel = channel_fixture(tenant)
      %{other_conversation: conversation_fixture(tenant, other_channel)}
    end

    defp client_api(conn, token, conversation) do
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/converger/conversations/#{conversation.id}/activities")
    end

    test "an unscoped token reaches conversations of its own channel only", %{conn: conn} = ctx do
      {:ok, token, _} = ConvergerToken.generate_token(ctx.channel)

      assert json_response(client_api(conn, token, ctx.conversation), 200)
      assert json_response(client_api(build_conn(), token, ctx.other_conversation), 404)
    end

    test "uploads and resume are channel scoped too", %{conn: conn} = ctx do
      {:ok, token, _} = ConvergerToken.generate_token(ctx.channel)

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/v1/converger/conversations/#{ctx.other_conversation.id}")

      assert json_response(resp, 404)
    end

    test "joining a conversation needs a conversation-bound token", ctx do
      {:ok, unscoped, _} = ConvergerToken.generate_token(ctx.channel)
      {:ok, socket} = Phoenix.ChannelTest.connect(ConvergerSocket, %{"token" => unscoped})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 ConvergerChannel,
                 "converger:conversation:#{ctx.conversation.id}"
               )

      {:ok, bound, _} =
        ConvergerToken.generate_conversation_token(ctx.channel, ctx.conversation.id)

      {:ok, socket} = Phoenix.ChannelTest.connect(ConvergerSocket, %{"token" => bound})

      assert {:ok, _, _} =
               subscribe_and_join(
                 socket,
                 ConvergerChannel,
                 "converger:conversation:#{ctx.conversation.id}"
               )
    end
  end

  describe "SSRF guard on other server-side URLs" do
    test "tenant alert_webhook_url rejects private targets", %{tenant: tenant} do
      assert {:error, changeset} =
               Tenants.update_tenant(tenant, %{alert_webhook_url: "http://169.254.169.254/x"})

      assert %{alert_webhook_url: [message]} = Converger.DataCase.errors_on(changeset)
      assert message =~ "not allowed"

      assert {:ok, _} =
               Tenants.update_tenant(tenant, %{alert_webhook_url: "https://alerts.example.com/h"})
    end

    test "Infobip base_url rejects private targets at config time and at send time" do
      config = %{"base_url" => "http://10.0.0.5", "api_key" => "k", "sender" => "s"}
      assert {:error, message} = WhatsAppInfobip.validate_config(config)
      assert message =~ "base_url is not allowed"

      # A channel saved before the guard existed is still refused at send time.
      channel = %{
        id: Ecto.UUID.generate(),
        type: "whatsapp_infobip",
        retry_policy: %{},
        config: config
      }

      activity = %{id: Ecto.UUID.generate(), text: "hi", metadata: %{"to" => "15550001"}}

      assert {:error, %DeliveryError{retryable?: false} = error} =
               WhatsAppInfobip.deliver_activity(channel, activity)

      assert DeliveryError.message(error) =~ "rejected"
    end
  end
end
