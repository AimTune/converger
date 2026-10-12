defmodule ConvergerWeb.ApiContractTest do
  @moduledoc """
  Every documented operation, called for real, answers what the OpenAPI
  description (`ConvergerWeb.ApiSpec`, priv/static/openapi.json) says:
  `OpenApiSpex.TestAssertions` checks each response body against the
  operation's response schema for its status (ADR-0050).
  """
  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.Auth.{ConvergerToken, Token}
  alias Converger.{Channels, Deliveries, Repo}
  alias Converger.Deliveries.Delivery
  alias ConvergerWeb.ApiSpec

  @spec_struct ApiSpec.spec()

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp api(tenant), do: build_conn() |> put_req_header("x-api-key", tenant.api_key)
  defp bearer(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp check(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    assert_api_response(conn)
  end

  describe "tenant API" do
    test "conversations", %{tenant: tenant, conversation: conversation} do
      api(tenant) |> get(~p"/api/v1/conversations") |> check(200)
      api(tenant) |> get(~p"/api/v1/conversations/#{conversation.id}") |> check(200)
      api(tenant) |> post(~p"/api/v1/conversations/#{conversation.id}/close") |> check(200)
      api(tenant) |> post(~p"/api/v1/conversations/#{conversation.id}/reopen") |> check(200)

      api(tenant) |> get(~p"/api/v1/conversations?cursor=nope") |> check(400)
      api(tenant) |> get(~p"/api/v1/conversations/#{Ecto.UUID.generate()}") |> check(404)
    end

    test "legacy channel-token endpoints", %{channel: channel, conversation: conversation} do
      {:ok, channel_token, _} = Token.generate_channel_token(channel)

      build_conn()
      |> put_req_header("x-channel-token", channel_token)
      |> post(~p"/api/v1/conversations", %{"metadata" => %{"k" => "v"}})
      |> check(201)

      build_conn()
      |> put_req_header("x-channel-token", channel_token)
      |> post(~p"/api/v1/tokens", %{"conversation_id" => conversation.id, "user_id" => "u-1"})
      |> check(201)
    end

    test "activities", %{tenant: tenant, conversation: conversation} do
      api(tenant)
      |> put_req_header("x-idempotency-key", "contract-1")
      |> post(~p"/api/v1/conversations/#{conversation.id}/activities", %{
        "text" => "hello",
        "sender" => "bot",
        "attachments" => [%{"contentType" => "image/png", "contentUrl" => "https://x/y.png"}]
      })
      |> check(201)

      api(tenant) |> get(~p"/api/v1/conversations/#{conversation.id}/activities") |> check(200)

      api(tenant)
      |> post(~p"/api/v1/conversations/#{conversation.id}/activities", %{"type" => "bogus"})
      |> check(422)

      api(tenant)
      |> get(~p"/api/v1/conversations/#{conversation.id}/activities?watermark=%25%25")
      |> check(400)
    end

    test "routing rules and dry-run", %{tenant: tenant, channel: channel} do
      target = webhook_channel_fixture(tenant)

      rule =
        api(tenant)
        |> post(~p"/api/v1/routing_rules", %{
          "routing_rule" => %{
            "name" => "contract",
            "source_channel_id" => channel.id,
            "target_channel_ids" => [target.id]
          }
        })
        |> check(201)
        |> json_response(201)
        |> get_in(["data", "id"])

      api(tenant) |> get(~p"/api/v1/routing_rules") |> check(200)
      api(tenant) |> get(~p"/api/v1/routing_rules/#{rule}") |> check(200)

      api(tenant)
      |> patch(~p"/api/v1/routing_rules/#{rule}", %{"routing_rule" => %{"priority" => 5}})
      |> check(200)

      api(tenant)
      |> post(~p"/api/v1/routing_rules/dry_run", %{
        "source_channel_id" => channel.id,
        "activity" => %{"text" => "hi"}
      })
      |> check(200)

      api(tenant)
      |> post(~p"/api/v1/routing_rules", %{"routing_rule" => %{"name" => ""}})
      |> check(422)

      api(tenant) |> delete(~p"/api/v1/routing_rules/#{rule}") |> check(204)
    end

    test "deliveries", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel_fixture(tenant))
      activity = activity_fixture(tenant, conversation)

      {:ok, delivery} =
        activity.id
        |> Deliveries.get_or_create_delivery(channel.id)
        |> Delivery.changeset(%{status: "failed", attempts: 5, last_error: "HTTP 500"})
        |> Repo.update()

      api(tenant) |> get(~p"/api/v1/deliveries?status=failed") |> check(200)
      api(tenant) |> post(~p"/api/v1/deliveries/#{delivery.id}/retry") |> check(202)
      api(tenant) |> post(~p"/api/v1/deliveries/#{delivery.id}/retry") |> check(409)
      api(tenant) |> post(~p"/api/v1/channels/#{channel.id}/deliveries/retry") |> check(202)
    end

    test "channel delivery state", %{tenant: tenant, channel: channel} do
      api(tenant) |> get(~p"/api/v1/channels/#{channel.id}/delivery") |> check(200)
      api(tenant) |> post(~p"/api/v1/channels/#{channel.id}/pause") |> check(200)
      api(tenant) |> post(~p"/api/v1/channels/#{channel.id}/resume") |> check(200)
    end

    test "templates of a channel type without templates", %{tenant: tenant, channel: channel} do
      api(tenant) |> get(~p"/api/v1/channels/#{channel.id}/templates") |> check(422)
    end

    test "platform event webhooks", %{tenant: tenant} do
      previous = Application.get_env(:converger, :platform_webhook_req_options)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:converger, :platform_webhook_req_options, previous),
          else: Application.delete_env(:converger, :platform_webhook_req_options)
      end)

      Application.put_env(:converger, :platform_webhook_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 400, "nope") end
      )

      api(tenant) |> get(~p"/api/v1/webhook_event_types") |> check(200)

      subscription =
        api(tenant)
        |> post(~p"/api/v1/webhook_subscriptions", %{
          "webhook_subscription" => %{
            "url" => "https://hooks.example.com/events",
            "events" => ["conversation.closed"],
            "headers" => %{"authorization" => "Bearer abc"}
          }
        })
        |> check(201)
        |> json_response(201)
        |> get_in(["data", "id"])

      api(tenant) |> get(~p"/api/v1/webhook_subscriptions") |> check(200)
      api(tenant) |> get(~p"/api/v1/webhook_subscriptions/#{subscription}") |> check(200)

      api(tenant)
      |> patch(~p"/api/v1/webhook_subscriptions/#{subscription}", %{
        "webhook_subscription" => %{"description" => "CRM"}
      })
      |> check(200)

      api(tenant)
      |> put(~p"/api/v1/webhook_subscriptions/#{subscription}", %{
        "webhook_subscription" => %{"enabled" => true}
      })
      |> check(200)

      api(tenant)
      |> post(~p"/api/v1/webhook_subscriptions/#{subscription}/rotate_secret")
      |> check(200)

      api(tenant)
      |> post(~p"/api/v1/webhook_subscriptions", %{
        "webhook_subscription" => %{"url" => "https://hooks.example.com/x", "events" => ["no"]}
      })
      |> check(422)

      api(tenant) |> post(~p"/api/v1/webhook_subscriptions", %{}) |> check(400)

      api(tenant)
      |> get(~p"/api/v1/webhook_subscriptions/#{Ecto.UUID.generate()}")
      |> check(404)

      Converger.Webhooks.emit(tenant.id, "conversation.closed", %{conversation_id: "c-1"})

      event =
        api(tenant)
        |> get(~p"/api/v1/webhook_events?status=failed&subscription_id=#{subscription}")
        |> check(200)
        |> json_response(200)
        |> get_in(["data", Access.at(0), "id"])

      api(tenant) |> get(~p"/api/v1/webhook_events?cursor=nope") |> check(400)
      api(tenant) |> get(~p"/api/v1/webhook_events/#{event}") |> check(200)
      api(tenant) |> get(~p"/api/v1/webhook_events/#{Ecto.UUID.generate()}") |> check(404)

      Application.put_env(:converger, :platform_webhook_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end
      )

      api(tenant) |> post(~p"/api/v1/webhook_events/#{event}/redeliver") |> check(202)
      api(tenant) |> post(~p"/api/v1/webhook_events/#{event}/redeliver") |> check(409)

      {:ok, channel_token, _} = Token.generate_channel_token(channel_fixture(tenant))

      build_conn()
      |> put_req_header("x-channel-token", channel_token)
      |> get(~p"/api/v1/webhook_events")
      |> check(403)

      api(tenant) |> delete(~p"/api/v1/webhook_subscriptions/#{subscription}") |> check(204)
    end

    test "pull outbox", %{tenant: tenant} do
      {:ok, channel} =
        Channels.create_channel(%{
          name: "pull-#{System.unique_integer([:positive])}",
          type: "http_pull",
          mode: "outbound",
          status: "active",
          tenant_id: tenant.id
        })

      page = api(tenant) |> get(~p"/api/v1/channels/#{channel.id}/outbox") |> check(200)
      watermark = json_response(page, 200)["watermark"]

      if watermark do
        api(tenant)
        |> post(~p"/api/v1/channels/#{channel.id}/outbox/ack", %{"watermark" => watermark})
        |> check(200)
      end

      api(tenant)
      |> post(~p"/api/v1/channels/#{channel.id}/outbox/ack", %{"watermark" => "nope"})
      |> check(400)
    end
  end

  describe "inbound webhooks" do
    test "messages and receipts", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "duplex"})

      build_conn()
      |> signed_post(~p"/api/v1/channels/#{channel.id}/inbound", channel, %{
        "text" => "hi",
        "sender" => "crm",
        "external_id" => "c-1"
      })
      |> check(201)

      build_conn()
      |> signed_post(~p"/api/v1/channels/#{channel.id}/status", channel, %{
        "provider_message_id" => "unknown",
        "status" => "delivered"
      })
      |> check(200)

      build_conn()
      |> signed_post(~p"/api/v1/channels/#{channel.id}/inbound", channel, %{"sender" => "x"})
      |> check(422)
    end
  end

  describe "client API" do
    test "tokens, conversations and activities", %{channel: channel} do
      token =
        bearer(channel.secret)
        |> post(~p"/api/v1/converger/tokens/generate", %{"user" => %{"id" => "u-1"}})
        |> check(200)
        |> json_response(200)
        |> Map.fetch!("token")

      bearer(token) |> post(~p"/api/v1/converger/tokens/refresh") |> check(200)

      %{"conversationId" => id, "token" => conversation_token} =
        bearer(token)
        |> post(~p"/api/v1/converger/conversations")
        |> check(201)
        |> json_response(201)

      bearer(conversation_token) |> get(~p"/api/v1/converger/conversations/#{id}") |> check(200)

      bearer(conversation_token)
      |> post(~p"/api/v1/converger/conversations/#{id}/activities", %{
        "text" => "hello",
        "from" => %{"id" => "u-1"}
      })
      |> check(200)

      bearer(conversation_token)
      |> get(~p"/api/v1/converger/conversations/#{id}/activities")
      |> check(200)

      bearer(conversation_token)
      |> post(~p"/api/v1/converger/conversations/#{id}/close")
      |> check(200)

      bearer(conversation_token)
      |> post(~p"/api/v1/converger/conversations/#{id}/activities", %{"text" => "late"})
      |> check(409)

      bearer(conversation_token)
      |> post(~p"/api/v1/converger/conversations/#{id}/reopen")
      |> check(200)

      bearer(conversation_token)
      |> get(~p"/api/v1/converger/conversations/#{Ecto.UUID.generate()}")
      |> check(403)

      build_conn() |> post(~p"/api/v1/converger/conversations") |> check(401)
    end

    test "upload", %{channel: channel, conversation: conversation} do
      {:ok, token, _} = ConvergerToken.generate_token(channel)
      path = Path.join(System.tmp_dir!(), "contract_#{System.unique_integer([:positive])}.png")
      File.write!(path, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy(<<0>>, 64))
      on_exit(fn -> File.rm(path) end)

      bearer(token)
      |> post(~p"/api/v1/converger/conversations/#{conversation.id}/upload", %{
        "file" => %Plug.Upload{path: path, filename: "a.png", content_type: "image/png"}
      })
      |> check(200)

      bearer(token)
      |> post(~p"/api/v1/converger/conversations/#{conversation.id}/upload", %{})
      |> check(400)
    end
  end

  test "the spec struct has an operation for every routed API action" do
    for route <- ConvergerWeb.Router.__routes__(),
        String.starts_with?(route.path, "/api/v1"),
        route.plug != ConvergerWeb.ProtocolSocketController do
      assert %OpenApiSpex.Operation{} = route.plug.open_api_operation(route.plug_opts),
             "no OpenAPI operation for #{route.verb} #{route.path}"
    end

    assert map_size(@spec_struct.paths) > 0
  end
end
