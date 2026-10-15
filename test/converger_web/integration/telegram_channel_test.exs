defmodule ConvergerWeb.Integration.TelegramChannelTest do
  # Telegram <-> agent console bridging through a `websocket` channel (#38).
  use ConvergerWeb.ChannelCase
  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Phoenix.LiveViewTest

  alias Converger.{Accounts, AuditLogs, Channels, Deliveries, Repo, RoutingRules, Uploads}
  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias Converger.Channels.Adapters.Telegram
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  @token "7000000001:AAFakeTokenForTests"
  @secret "tg_secret-token"
  @chat "123456789"
  # Smallest JPEG header the MIME sniffer recognises.
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>

  setup do
    test_pid = self()

    Req.Test.stub(Telegram, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.request_path do
        "/file/bot" <> _ ->
          send(test_pid, {:telegram_download, conn.request_path})
          Plug.Conn.send_resp(conn, 200, @jpeg)

        path ->
          method = path |> String.split("/") |> List.last()
          params = if body == "", do: %{}, else: Jason.decode!(body)
          send(test_pid, {:telegram, method, params})
          Req.Test.json(conn, %{"ok" => true, "result" => result(method, params)})
      end
    end)

    tenant = tenant_fixture()

    {:ok, telegram} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "telegram",
        mode: "duplex",
        status: "active",
        require_signature: true,
        tenant_id: tenant.id,
        config: %{"bot_token" => @token, "secret_token" => @secret}
      })

    console = channel_fixture(tenant, %{mode: "duplex"})

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "telegram to console",
        tenant_id: tenant.id,
        source_channel_id: telegram.id,
        target_channel_ids: [console.id]
      })

    %{tenant: tenant, telegram: telegram, console: console}
  end

  defp result("sendMessage", params),
    do: %{"message_id" => 900, "chat" => %{"id" => String.to_integer(params["chat_id"])}}

  defp result("getFile", %{"file_id" => id}),
    do: %{"file_id" => id, "file_path" => "photos/file_1.jpg", "file_size" => 18}

  defp result(_method, _params), do: true

  defp fixture(name) do
    "test/fixtures/telegram/#{name}.json" |> File.read!() |> Jason.decode!()
  end

  defp post_update(channel, update, secret \\ @secret) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")

    conn =
      if secret,
        do: put_req_header(conn, "x-telegram-bot-api-secret-token", secret),
        else: conn

    post(conn, ~p"/api/v1/channels/#{channel.id}/inbound", Jason.encode!(update))
  end

  defp inbound!(channel, update) do
    [activity_id] =
      channel
      |> post_update(update)
      |> json_response(200)
      |> Map.fetch!("activity_ids")

    Repo.get!(Activity, activity_id)
  end

  defp join_console(console) do
    {:ok, token, _} = ConvergerToken.generate_token(console, scope: "channel", user_id: "agent-7")
    {:ok, socket} = Phoenix.ChannelTest.connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:channel:#{console.id}")

    socket
  end

  describe "Telegram -> websocket channel" do
    test "a message reaches the console and the reply goes back to the same chat", %{
      telegram: telegram,
      console: console
    } do
      socket = join_console(console)

      inbound = inbound!(telegram, fixture("message_text"))
      conversation_id = inbound.conversation_id

      assert inbound.text == "Where is my order?"
      assert inbound.sender == @chat
      assert inbound.idempotency_key == "#{@chat}:41"

      assert_push "activitySet", %{conversation_id: ^conversation_id, activities: [frame]}
      assert frame.text == "Where is my order?"

      # Not echoed back to Telegram.
      refute_received {:telegram, "sendMessage", _}

      ref =
        Phoenix.ChannelTest.push(socket, "postActivity", %{
          "conversation_id" => conversation_id,
          "text" => "It ships today",
          "clientId" => "reply-1"
        })

      assert_reply ref, :ok, %{id: reply_id}, 2_000

      assert_received {:telegram, "sendMessage",
                       %{"chat_id" => @chat, "text" => "It ships today"}}

      assert %{status: "sent", provider_message_id: provider_id} =
               Deliveries.get_delivery_for_activity_and_channel(reply_id, telegram.id)

      assert provider_id == "#{@chat}:900"
    end

    test "a re-delivered update creates no second activity", %{telegram: telegram} do
      first = inbound!(telegram, fixture("message_text"))

      body =
        telegram
        |> post_update(fixture("message_text"))
        |> json_response(200)

      assert body["activity_ids"] == [first.id]
      assert body["duplicates"] == 1
    end

    test "an edit and a reaction refer to the original message", %{telegram: telegram} do
      original = inbound!(telegram, fixture("message_text"))

      edit = inbound!(telegram, fixture("edited_message"))
      assert edit.type == "messageUpdate"
      assert edit.reply_to_id == original.id
      assert edit.conversation_id == original.conversation_id
      assert Repo.get!(Activity, original.id).edited_at

      reaction = inbound!(telegram, fixture("message_reaction"))
      assert reaction.type == "messageReaction"
      assert reaction.text == "👍"
      assert reaction.reply_to_id == original.id
    end

    test "a reaction to an unknown message is kept as an event", %{telegram: telegram} do
      reaction = inbound!(telegram, fixture("message_reaction"))
      assert reaction.type == "event"
      assert reaction.metadata["reaction"]["message_id"] == "#{@chat}:41"
    end

    test "a photo is downloaded with getFile and stored as an attachment", %{
      telegram: telegram,
      tenant: tenant
    } do
      activity = inbound!(telegram, fixture("message_photo"))

      assert_received {:telegram, "getFile", %{"file_id" => "AgACAgQAAxkBAAMlarge"}}
      assert_received {:telegram_download, "/file/bot" <> _}

      assert activity.text == "The damaged box"

      assert [%{"contentUrl" => "/api/v1/converger/attachments/" <> id} = attachment] =
               activity.attachments

      assert attachment["contentType"] == "image/jpeg"
      assert attachment["channelData"]["fileId"] == "AgACAgQAAxkBAAMlarge"
      assert %Uploads.Attachment{size: size} = Uploads.get_attachment(tenant.id, id)
      assert size == byte_size(@jpeg)
      # The Bot API download URL embeds the bot token: never stored.
      refute Jason.encode!(activity.attachments) =~ @token
    end

    test "a callback button press is stored as an event and answered", %{telegram: telegram} do
      event = inbound!(telegram, fixture("callback_query"))

      assert event.type == "event"
      assert event.text == "track_order"
      assert_receive {:telegram, "answerCallbackQuery", %{"callback_query_id" => _}}
    end

    test "an update type Converger does not handle is acknowledged", %{telegram: telegram} do
      assert %{"status" => "accepted"} =
               telegram |> post_update(fixture("my_chat_member")) |> json_response(200)
    end
  end

  describe "secret token" do
    test "an invalid secret token is rejected with 401", %{telegram: telegram} do
      conn = post_update(telegram, fixture("message_text"), "not-the-secret")
      assert conn.status == 401
      assert Repo.aggregate(Activity, :count) == 0
    end

    test "a missing secret token is rejected with 401", %{telegram: telegram} do
      conn = post_update(telegram, fixture("message_text"), nil)
      assert conn.status == 401
    end
  end

  describe "admin: register webhook" do
    setup %{conn: conn} do
      {:ok, admin} =
        Accounts.create_admin_user(%{
          email: "tg-admin-#{System.unique_integer([:positive])}@test.com",
          password: "testpassword123",
          name: "Telegram Admin",
          role: "super_admin"
        })

      conn =
        conn
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> log_in_admin(admin)

      %{conn: conn, admin: admin}
    end

    test "calls setWebhook with the inbound URL and secret, and audits it", %{
      conn: conn,
      telegram: telegram,
      console: console
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/channels")

      # Only adapters with register_webhook/2 get the button.
      refute has_element?(view, "#register-webhook-#{console.id}")

      html = view |> element("#register-webhook-#{telegram.id}") |> render_click()
      assert html =~ "Webhook registered"

      assert_received {:telegram, "setWebhook", params}
      assert params["url"] == url(~p"/api/v1/channels/#{telegram.id}/inbound")
      assert params["secret_token"] == @secret

      assert [%{action: "register_webhook"}] =
               AuditLogs.list_audit_logs(%{"action" => "register_webhook"})
               |> Enum.filter(&(&1.resource_id == telegram.id))
    end
  end
end
