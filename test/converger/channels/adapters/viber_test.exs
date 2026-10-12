defmodule Converger.Channels.Adapters.ViberTest do
  # Global Req stub (config :converger, :viber_req_options): not async.
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures

  alias Converger.Activities.Activity
  alias Converger.{Channels, Deliveries, Participants, Repo, Uploads}
  alias Converger.Channels.{Adapter, DeliveryError, InboundSignature}
  alias Converger.Channels.Adapters.Viber

  @token "445da6az1s345z78-dazcczb2542zv51a-e0vc5fva17480im9"
  @user "01234567890A="
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::size(256)>>

  setup do
    Application.put_env(:converger, :viber_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:converger, :viber_req_options) end)

    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: "viber-#{System.unique_integer([:positive])}",
        type: "viber",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{"auth_token" => @token, "sender_name" => "Acme Support"}
      })

    %{tenant: tenant, channel: channel}
  end

  defp stub_api(
         respond \\ fn _method, _body ->
           %{"status" => 0, "message_token" => 5_098_034_272_017_990_000}
         end
       ) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      method = conn.request_path |> String.split("/") |> List.last()
      decoded = if body == "", do: %{}, else: Jason.decode!(body)

      send(
        test_pid,
        {:viber, method, Plug.Conn.get_req_header(conn, "x-viber-auth-token"), decoded}
      )

      case respond.(method, decoded) do
        {status, response} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
        response -> Req.Test.json(conn, response)
      end
    end)
  end

  defp activity(attrs) do
    struct(
      Activity,
      Map.merge(
        %{text: nil, attachments: [], metadata: %{"recipient_id" => @user}},
        Map.new(attrs)
      )
    )
  end

  defp post_callback(conn, channel, params, signature \\ :valid) do
    body = Jason.encode!(params)

    conn =
      case signature do
        :valid ->
          put_req_header(
            conn,
            "x-viber-content-signature",
            InboundSignature.hmac_hex(@token, body)
          )

        :none ->
          conn

        value ->
          put_req_header(conn, "x-viber-content-signature", value)
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/channels/#{channel.id}/inbound", body)
  end

  defp message_callback(message, token \\ 4_912_661_846_655_238_145) do
    %{
      "event" => "message",
      "timestamp" => 1_457_764_197_627,
      "message_token" => token,
      "sender" => %{
        "id" => @user,
        "name" => "John McClane",
        "language" => "en",
        "country" => "US"
      },
      "message" => message
    }
  end

  test "is registered as a duplex built-in with webhook registration" do
    assert {:ok, Viber} = Adapter.adapter_for("viber")
    assert Viber.supported_modes() == ~w(inbound outbound duplex)
    assert Adapter.supports?("viber", :register_webhook, 2)
  end

  test "config requires the token and a short sender name" do
    assert {:error, message} = Adapter.validate_config("viber", %{"sender_name" => "x"})
    assert message =~ "auth_token"

    assert {:error, message} =
             Adapter.validate_config("viber", %{
               "auth_token" => @token,
               "sender_name" => String.duplicate("a", 29)
             })

    assert message =~ "28"
  end

  describe "signature" do
    test "accepts the HMAC of the body and rejects a wrong or missing one", %{channel: channel} do
      assert :ok =
               Viber.verify_inbound_signature(
                 channel,
                 [{"x-viber-content-signature", InboundSignature.hmac_hex(@token, "{}")}],
                 "{}"
               )

      assert {:error, :invalid_signature} =
               Viber.verify_inbound_signature(
                 channel,
                 [{"x-viber-content-signature", "00"}],
                 "{}"
               )

      assert {:error, :missing_signature} = Viber.verify_inbound_signature(channel, [], "{}")
    end

    test "an unsigned callback is rejected with 401", %{conn: conn, channel: channel} do
      conn =
        post_callback(conn, channel, message_callback(%{"type" => "text", "text" => "hi"}), :none)

      assert json_response(conn, 401)
    end
  end

  describe "inbound" do
    test "the set_webhook check is answered 200", %{conn: conn, channel: channel} do
      conn =
        post_callback(conn, channel, %{
          "event" => "webhook",
          "timestamp" => 1_457_764_197_627,
          "message_token" => 241_256_543_215
        })

      assert json_response(conn, 200)["status"] == "accepted"
    end

    test "a text message creates an activity once", %{conn: conn, channel: channel} do
      params = message_callback(%{"type" => "text", "text" => "Hello Viber"})
      conn = post_callback(conn, channel, params)
      assert %{"activity_ids" => [id]} = json_response(conn, 200)

      activity = Repo.get!(Activity, id)
      assert activity.text == "Hello Viber"
      assert activity.sender == @user
      assert activity.idempotency_key == "4912661846655238145"
      assert activity.metadata["language"] == "en"

      assert Participants.get_participant_by_external_id(channel.id, @user).display_name ==
               "John McClane"

      conn = post_callback(build_conn(), channel, params)
      assert json_response(conn, 200)["duplicates"] == 1
    end

    test "a picture is downloaded and stored", %{conn: conn, channel: channel} do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:download, conn.host, conn.request_path})
        conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, @png)
      end)

      params =
        message_callback(%{
          "type" => "picture",
          "text" => "look",
          "media" => "https://dl-media.viber.com/1/share/2/long/bots/generic/pic.png"
        })

      conn = post_callback(conn, channel, params)
      assert %{"activity_ids" => [id]} = json_response(conn, 200)

      activity = Repo.get!(Activity, id)
      assert activity.text == "look"
      [attachment] = activity.attachments
      assert attachment["contentUrl"] =~ "/api/v1/converger/attachments/"
      assert attachment["channelData"]["kind"] == "picture"
      assert_received {:download, "dl-media.viber.com", _}
    end

    test "location and contact messages" do
      assert {:ok, [location]} =
               Viber.parse_inbound(
                 %{},
                 message_callback(%{
                   "type" => "location",
                   "location" => %{"lat" => 50.76891, "lon" => 6.11499, "address" => "Aachen"}
                 })
               )

      assert [%{"contentType" => "application/vnd.converger.location", "content" => content}] =
               location["attachments"]

      assert content["latitude"] == 50.76891

      assert {:ok, [contact]} =
               Viber.parse_inbound(
                 %{},
                 message_callback(%{
                   "type" => "contact",
                   "contact" => %{"name" => "Alice", "phone_number" => "+972511123123"}
                 })
               )

      assert contact["text"] == "Alice"
    end

    test "unsubscribed opts the participant out, subscribed opts it in", %{
      conn: conn,
      channel: channel
    } do
      conn =
        post_callback(conn, channel, %{
          "event" => "unsubscribed",
          "timestamp" => 1_457_764_197_627,
          "user_id" => @user,
          "message_token" => 4_912_661_846_655_238_146
        })

      assert %{"activity_ids" => [id]} = json_response(conn, 200)
      assert Repo.get!(Activity, id).metadata["name"] == "viber.unsubscribed"
      assert Participants.opted_out?(channel.id, @user)

      conn =
        post_callback(build_conn(), channel, %{
          "event" => "subscribed",
          "timestamp" => 1_457_764_197_628,
          "user" => %{"id" => @user, "name" => "John"},
          "message_token" => 4_912_661_846_655_238_147
        })

      assert json_response(conn, 200)
      refute Participants.opted_out?(channel.id, @user)
    end

    test "conversation_started is an event", %{channel: channel} do
      assert {:ok, [event]} =
               Viber.parse_inbound(channel, %{
                 "event" => "conversation_started",
                 "timestamp" => 1,
                 "message_token" => 42,
                 "type" => "open",
                 "context" => "campaign-1",
                 "user" => %{"id" => @user, "name" => "John"},
                 "subscribed" => false
               })

      assert event["type"] == "event"
      assert event["metadata"]["name"] == "viber.conversation_started"
      assert event["metadata"]["context"] == "campaign-1"
      refute Map.has_key?(event, "opt_out")
    end

    test "delivered, seen and failed receipts", %{channel: channel} do
      for {event, status} <- [{"delivered", "delivered"}, {"seen", "read"}, {"failed", "failed"}] do
        assert {:ok, [%{"provider_message_id" => "4912661846655238145", "status" => ^status}]} =
                 Viber.parse_status_update(channel, %{
                   "event" => event,
                   "timestamp" => 1_457_764_197_627,
                   "message_token" => 4_912_661_846_655_238_145,
                   "user_id" => @user
                 })
      end
    end
  end

  describe "outbound" do
    test "text with a keyboard from card buttons", %{channel: channel} do
      stub_api()

      activity =
        activity(
          text: "How can we help?",
          attachments: [
            %{
              "contentType" => "application/vnd.converger.card.buttons",
              "content" => %{
                "buttons" => [
                  %{"id" => "orders", "title" => "Orders"},
                  %{"type" => "openUrl", "title" => "FAQ", "value" => "https://example.com/faq"}
                ]
              }
            }
          ]
        )

      assert {:ok, %{provider_message_id: "5098034272017990000"}} =
               Viber.deliver_activity(channel, activity)

      assert_received {:viber, "send_message", [@token], body}
      assert body["receiver"] == @user
      assert body["sender"] == %{"name" => "Acme Support"}
      assert body["type"] == "text"
      assert body["text"] == "How can we help?"

      assert [
               %{"ActionType" => "reply", "ActionBody" => "orders", "Text" => "Orders"},
               %{"ActionType" => "open-url", "ActionBody" => "https://example.com/faq"}
             ] = body["keyboard"]["Buttons"]
    end

    test "pictures, files, locations and contacts", %{channel: channel} do
      stub_api()

      activity =
        activity(
          text: "Details",
          attachments: [
            %{"contentType" => "image/jpeg", "contentUrl" => "https://example.com/p.jpg"},
            %{
              "contentType" => "application/pdf",
              "contentUrl" => "https://example.com/doc.pdf",
              "name" => "doc.pdf",
              "size" => 1024
            },
            %{
              "contentType" => "application/pdf",
              "contentUrl" => "https://example.com/nosize.pdf"
            },
            %{
              "contentType" => "application/vnd.converger.location",
              "content" => %{"latitude" => 1.5, "longitude" => 2.5}
            },
            %{
              "contentType" => "application/vnd.converger.contacts",
              "content" => [%{"name" => "Bob", "phones" => ["+15550100"]}]
            }
          ]
        )

      assert {:ok, %{viber_message_tokens: tokens}} = Viber.deliver_activity(channel, activity)
      assert length(tokens) == 6

      types =
        for _ <- 1..6 do
          assert_received {:viber, "send_message", _, body}
          body
        end

      assert [
               %{"type" => "picture", "media" => "https://example.com/p.jpg"},
               %{"type" => "file", "size" => 1024, "file_name" => "doc.pdf"},
               %{"type" => "url", "media" => "https://example.com/nosize.pdf"},
               %{"type" => "location", "location" => %{"lat" => 1.5, "lon" => 2.5}},
               %{
                 "type" => "contact",
                 "contact" => %{"name" => "Bob", "phone_number" => "+15550100"}
               },
               %{"type" => "text", "text" => "Details"}
             ] = types
    end

    test "a stored upload cannot be sent", %{channel: channel, tenant: tenant} do
      {:ok, stored} = Uploads.create_attachment(tenant.id, {"p.png", @png})

      activity =
        activity(
          attachments: [
            %{
              "contentType" => "image/png",
              "contentUrl" => "/api/v1/converger/attachments/#{stored.id}"
            }
          ]
        )

      assert {:error, %DeliveryError{retryable?: false}} =
               Viber.deliver_activity(channel, activity)
    end

    test "status codes are classified", %{channel: channel} do
      for {status, retryable} <- [{6, false}, {5, false}, {12, true}, {99, true}] do
        stub_api(fn _, _ -> %{"status" => status, "status_message" => "error #{status}"} end)

        assert {:error, %DeliveryError{retryable?: ^retryable}} =
                 Viber.deliver_activity(channel, activity(text: "hi"))
      end

      stub_api(fn _, _ -> {503, %{}} end)

      assert {:error, %DeliveryError{retryable?: true}} =
               Viber.deliver_activity(channel, activity(text: "hi"))
    end

    test "a seen callback marks the delivery read", %{conn: conn, channel: channel} do
      conn =
        post_callback(conn, channel, message_callback(%{"type" => "text", "text" => "hi"}, 77))

      %{"activity_ids" => [id]} = json_response(conn, 200)

      {:ok, delivery} =
        Deliveries.create_delivery(%{
          activity_id: id,
          channel_id: channel.id,
          status: "sent",
          provider_message_id: "5098034272017990000"
        })

      conn =
        post_callback(build_conn(), channel, %{
          "event" => "seen",
          "timestamp" => 1_457_764_197_627,
          "message_token" => 5_098_034_272_017_990_000,
          "user_id" => @user
        })

      assert json_response(conn, 200)["receipts_processed"] == 1
      assert Deliveries.get_delivery!(delivery.id).status == "read"
    end

    test "register_webhook and health_probe", %{channel: channel} do
      stub_api(fn _, _ -> %{"status" => 0, "event_types" => []} end)

      assert :ok = Viber.register_webhook(channel, "https://converger.example.com/in")

      assert_received {:viber, "set_webhook", _,
                       %{"url" => "https://converger.example.com/in"} = body}

      assert "conversation_started" in body["event_types"]

      assert :ok = Viber.health_probe(channel)

      stub_api(fn _, _ -> %{"status" => 2, "status_message" => "invalidAuthToken"} end)
      assert {:error, message} = Viber.health_probe(channel)
      assert message =~ "invalidAuthToken"
    end
  end
end
