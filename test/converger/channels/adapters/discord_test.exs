defmodule Converger.Channels.Adapters.DiscordTest do
  # Global Req stub (config :converger, :discord_req_options): not async.
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures

  alias Converger.Activities.Activity
  alias Converger.{Channels, Repo, Uploads}
  alias Converger.Channels.{Adapter, DeliveryError}
  alias Converger.Channels.Adapters.Discord

  @app_id "1234567890123456789"
  @discord_channel "987654321098765432"
  @user_id "111111111111111111"
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::size(256)>>

  setup do
    Application.put_env(:converger, :discord_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:converger, :discord_req_options) end)

    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: "discord-#{System.unique_integer([:positive])}",
        type: "discord",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "application_id" => @app_id,
          "public_key" => Base.encode16(public, case: :lower),
          "bot_token" => "bot-token"
        }
      })

    %{tenant: tenant, channel: channel, private: private}
  end

  defp sign(private, body, timestamp \\ System.system_time(:second)) do
    timestamp = to_string(timestamp)
    signature = :crypto.sign(:eddsa, :none, timestamp <> body, [private, :ed25519])
    {Base.encode16(signature, case: :lower), timestamp}
  end

  defp post_interaction(conn, channel, private, params) do
    body = Jason.encode!(params)
    {signature, timestamp} = sign(private, body)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-signature-ed25519", signature)
    |> put_req_header("x-signature-timestamp", timestamp)
    |> post(~p"/api/v1/channels/#{channel.id}/inbound", body)
  end

  defp interaction(type, data, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "interaction-#{System.unique_integer([:positive])}",
        "application_id" => @app_id,
        "type" => type,
        "token" => "interaction-token",
        "version" => 1,
        "guild_id" => "555",
        "channel_id" => @discord_channel,
        "channel" => %{"id" => @discord_channel, "type" => 0},
        "member" => %{
          "nick" => "Ada (support)",
          "user" => %{"id" => @user_id, "username" => "ada", "global_name" => "Ada"}
        },
        "data" => data,
        "locale" => "en-US"
      },
      extra
    )
  end

  defp stub_api(
         respond \\ fn _method, _path, _body ->
           %{"id" => "msg-#{System.unique_integer([:positive])}"}
         end
       ) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:discord, conn.method, conn.request_path,
         Plug.Conn.get_req_header(conn, "authorization"),
         Plug.Conn.get_req_header(conn, "content-type"), body}
      )

      case respond.(conn.method, conn.request_path, body) do
        {status, response} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
        response -> Req.Test.json(conn, response)
      end
    end)
  end

  defp activity(attrs) do
    struct(
      Activity,
      Map.merge(
        %{text: nil, attachments: [], metadata: %{"target_channel_id" => @discord_channel}},
        Map.new(attrs)
      )
    )
  end

  test "is registered as a duplex built-in" do
    assert {:ok, Discord} = Adapter.adapter_for("discord")
    assert Discord.supported_modes() == ~w(inbound outbound duplex)
    assert Adapter.rate_limit("discord") == "50/s"
    assert Adapter.supports?("discord", :register_webhook, 2)
  end

  test "config requires a hex public key and a numeric application id" do
    base = %{
      "application_id" => @app_id,
      "public_key" => String.duplicate("ab", 32),
      "bot_token" => "t"
    }

    assert :ok = Adapter.validate_config("discord", base)
    assert {:error, msg} = Adapter.validate_config("discord", %{base | "public_key" => "xyz"})
    assert msg =~ "public_key"
    assert {:error, _} = Adapter.validate_config("discord", %{base | "application_id" => "app"})
  end

  describe "Ed25519 signature" do
    test "accepts a valid signature", %{channel: channel, private: private} do
      {signature, timestamp} = sign(private, "{}")

      assert :ok =
               Discord.verify_inbound_signature(
                 channel,
                 [{"x-signature-ed25519", signature}, {"x-signature-timestamp", timestamp}],
                 "{}"
               )
    end

    test "rejects a tampered body, a stale timestamp and missing headers", %{
      channel: channel,
      private: private
    } do
      {signature, timestamp} = sign(private, "{}")
      headers = [{"x-signature-ed25519", signature}, {"x-signature-timestamp", timestamp}]

      assert {:error, :invalid_signature} =
               Discord.verify_inbound_signature(channel, headers, "{ }")

      {stale, old} = sign(private, "{}", System.system_time(:second) - 3600)

      assert {:error, :timestamp_out_of_tolerance} =
               Discord.verify_inbound_signature(
                 channel,
                 [{"x-signature-ed25519", stale}, {"x-signature-timestamp", old}],
                 "{}"
               )

      assert {:error, :missing_signature} = Discord.verify_inbound_signature(channel, [], "{}")

      assert {:error, :malformed_signature} =
               Discord.verify_inbound_signature(
                 channel,
                 [{"x-signature-ed25519", "zz"}, {"x-signature-timestamp", timestamp}],
                 "{}"
               )
    end

    test "an invalid signature on the endpoint is a 401", %{conn: conn, channel: channel} do
      {other_public, other_private} = :crypto.generate_key(:eddsa, :ed25519)
      _ = other_public
      conn = post_interaction(conn, channel, other_private, %{"type" => 1})
      assert json_response(conn, 401)
    end
  end

  describe "inbound" do
    test "PING is answered with PONG", %{conn: conn, channel: channel, private: private} do
      conn = post_interaction(conn, channel, private, %{"type" => 1, "id" => "1"})
      assert json_response(conn, 200) == %{"type" => 1}
      assert Repo.aggregate(Activity, :count) == 0
    end

    test "a slash command creates a message and gets an ephemeral acknowledgement", %{
      conn: conn,
      channel: channel,
      private: private
    } do
      params =
        interaction(2, %{
          "id" => "cmd-1",
          "name" => "support",
          "options" => [%{"name" => "question", "type" => 3, "value" => "Where is my order?"}]
        })

      conn = post_interaction(conn, channel, private, params)

      assert json_response(conn, 200) == %{
               "type" => 4,
               "data" => %{"content" => "Got it, a reply is on its way.", "flags" => 64}
             }

      [activity] = Repo.all(Activity)
      assert activity.text == "/support Where is my order?"
      assert activity.sender == @user_id
      assert activity.idempotency_key == "interaction:" <> params["id"]
      assert activity.metadata["discord_channel_id"] == @discord_channel
      assert activity.metadata["discord_command"]["name"] == "support"

      # The participant is the user; replies go to the channel it last used.
      participant = Converger.Participants.get_participant_by_external_id(channel.id, @user_id)
      assert participant.display_name == "Ada (support)"
      assert participant.metadata == %{"discord_channel_id" => @discord_channel}
    end

    test "a button press is an event answered with a deferred update", %{
      conn: conn,
      channel: channel,
      private: private
    } do
      params =
        interaction(3, %{"custom_id" => "track", "component_type" => 2}, %{
          "message" => %{"id" => "msg-1"},
          "channel" => %{"id" => "thread-9", "type" => 11}
        })

      conn = post_interaction(conn, channel, private, params)
      assert json_response(conn, 200) == %{"type" => 6}

      [activity] = Repo.all(Activity)
      assert activity.type == "event"
      assert activity.text == "track"
      assert activity.metadata["name"] == "discord.component"
      assert activity.metadata["discord_thread_id"] == "thread-9"
    end

    test "modal submits and subcommands" do
      assert {:ok, [modal]} =
               Discord.parse_inbound(
                 %{},
                 interaction(5, %{
                   "custom_id" => "feedback",
                   "components" => [
                     %{
                       "type" => 1,
                       "components" => [%{"type" => 4, "custom_id" => "text", "value" => "Great"}]
                     }
                   ]
                 })
               )

      assert modal["text"] == "Great"

      assert {:ok, [command]} =
               Discord.parse_inbound(
                 %{},
                 interaction(2, %{
                   "name" => "ticket",
                   "options" => [
                     %{
                       "name" => "open",
                       "type" => 1,
                       "options" => [%{"name" => "title", "type" => 3, "value" => "Broken"}]
                     }
                   ]
                 })
               )

      assert command["text"] == "/ticket Broken"
    end

    test "autocomplete is answered with no choices and creates nothing", %{channel: channel} do
      assert {:ok, []} = Discord.parse_inbound(channel, %{"type" => 4})

      assert {"application/json", body} = Discord.inbound_response(channel, %{"type" => 4})
      assert Jason.decode!(body) == %{"type" => 8, "data" => %{"choices" => []}}
    end
  end

  describe "outbound" do
    test "text with buttons as components", %{channel: channel} do
      stub_api()

      activity =
        activity(
          text: "Pick one",
          attachments: [
            %{
              "contentType" => "application/vnd.converger.card.buttons",
              "content" => %{
                "buttons" => [
                  %{"id" => "a", "title" => "Option A"},
                  %{"type" => "openUrl", "title" => "Docs", "value" => "https://example.com"}
                ]
              }
            }
          ]
        )

      assert {:ok, %{provider_message_id: "msg-" <> _}} =
               Discord.deliver_activity(channel, activity)

      assert_received {:discord, "POST", "/api/v10/channels/" <> @discord_channel <> "/messages",
                       ["Bot bot-token"], _, body}

      body = Jason.decode!(body)
      assert body["content"] == "Pick one"

      assert [
               %{
                 "type" => 1,
                 "components" => [
                   %{"style" => 1, "custom_id" => "a", "label" => "Option A"},
                   %{"style" => 5, "url" => "https://example.com"}
                 ]
               }
             ] = body["components"]
    end

    test "long text is split and stored files are uploaded", %{channel: channel, tenant: tenant} do
      stub_api()
      {:ok, stored} = Uploads.create_attachment(tenant.id, {"chart.png", @png})

      activity =
        activity(
          text: String.duplicate("x", 2500),
          attachments: [
            %{
              "contentType" => "image/png",
              "contentUrl" => "/api/v1/converger/attachments/#{stored.id}"
            }
          ]
        )

      assert {:ok, %{discord_message_ids: [_, _]}} = Discord.deliver_activity(channel, activity)

      assert_received {:discord, "POST", _, _, ["multipart/form-data" <> _], first}
      assert first =~ ~s(name="payload_json")
      assert first =~ ~s(name="files[0]"; filename="chart.png")

      assert_received {:discord, "POST", _, _, _, second}
      assert String.length(Jason.decode!(second)["content"]) == 500
    end

    test "starts a thread from the first message", %{channel: channel} do
      stub_api(fn _method, path, _ ->
        if String.ends_with?(path, "/threads"),
          do: %{"id" => "thread-1"},
          else: %{"id" => "m-#{System.unique_integer([:positive])}"}
      end)

      activity =
        activity(
          text: String.duplicate("y", 2100),
          metadata: %{"target_channel_id" => @discord_channel, "thread_name" => "Order #42"}
        )

      assert {:ok, %{discord_thread_id: "thread-1", discord_message_ids: [_, _]}} =
               Discord.deliver_activity(channel, activity)

      assert_received {:discord, "POST", "/api/v10/channels/" <> @discord_channel <> "/messages",
                       _, _, _}

      assert_received {:discord, "POST",
                       "/api/v10/channels/" <> @discord_channel <> "/messages/m-" <> _, _, _,
                       thread_body}

      assert Jason.decode!(thread_body)["name"] == "Order #42"
      assert_received {:discord, "POST", "/api/v10/channels/thread-1/messages", _, _, _}
    end

    test "errors are classified, with retry_after from the body", %{channel: channel} do
      stub_api(fn _, _, _ ->
        {429,
         %{"message" => "You are being rate limited.", "retry_after" => 1.5, "global" => false}}
      end)

      assert {:error, %DeliveryError{retryable?: true, retry_after_ms: 1500}} =
               Discord.deliver_activity(channel, activity(text: "hi"))

      stub_api(fn _, _, _ -> {403, %{"code" => 50_013, "message" => "Missing Permissions"}} end)

      assert {:error, %DeliveryError{retryable?: false}} =
               Discord.deliver_activity(channel, activity(text: "hi"))
    end

    test "a reply in an interaction conversation goes to its channel", %{
      conn: conn,
      channel: channel,
      private: private
    } do
      conn = post_interaction(conn, channel, private, interaction(2, %{"name" => "help"}))
      assert json_response(conn, 200)
      [inbound] = Repo.all(Activity)

      stub_api()

      assert {:ok, _} =
               Discord.deliver_activity(
                 channel,
                 activity(conversation_id: inbound.conversation_id, text: "Hi Ada", metadata: %{})
               )

      assert_received {:discord, "POST", "/api/v10/channels/" <> @discord_channel <> "/messages",
                       _, _, _}
    end

    test "health probe and interactions endpoint registration", %{channel: channel} do
      stub_api(fn _, _, _ -> %{"id" => @app_id} end)
      assert :ok = Discord.health_probe(channel)
      assert_received {:discord, "GET", "/api/v10/users/@me", _, _, _}

      assert :ok = Discord.register_webhook(channel, "https://converger.example.com/in")
      assert_received {:discord, "PATCH", "/api/v10/applications/@me", _, _, body}

      assert Jason.decode!(body) == %{
               "interactions_endpoint_url" => "https://converger.example.com/in"
             }
    end
  end
end
