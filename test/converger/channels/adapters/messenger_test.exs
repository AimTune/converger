defmodule Converger.Channels.Adapters.MessengerTest do
  # Global Req stub (config :converger, :messenger_req_options): not async.
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures

  alias Converger.Activities.Activity
  alias Converger.{Channels, Deliveries, Repo, Uploads}
  alias Converger.Channels.{Adapter, DeliveryError, InboundSignature}
  alias Converger.Channels.Adapters.Messenger

  @app_secret "messenger-app-secret"
  @page_id "104512345678901"
  @psid "6789012345678901"
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::size(256)>>

  setup do
    Application.put_env(:converger, :messenger_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:converger, :messenger_req_options) end)

    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: "messenger-#{System.unique_integer([:positive])}",
        type: "messenger",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "page_id" => @page_id,
          "page_access_token" => "page-token",
          "verify_token" => "verify-me",
          "app_secret" => @app_secret
        }
      })

    %{tenant: tenant, channel: channel}
  end

  defp stub_graph(respond) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:graph, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "content-type"),
         body}
      )

      respond.(conn, body)
    end)
  end

  defp ok_message(conn),
    do:
      Req.Test.json(conn, %{
        "recipient_id" => @psid,
        "message_id" => "m_out-#{System.unique_integer([:positive])}"
      })

  defp activity(attrs) do
    struct(
      Activity,
      Map.merge(
        %{text: nil, attachments: [], metadata: %{"recipient_id" => @psid}},
        Map.new(attrs)
      )
    )
  end

  defp webhook(events) do
    %{
      "object" => "page",
      "entry" => [%{"id" => @page_id, "time" => 1_700_000_000_000, "messaging" => events}]
    }
  end

  defp event(extra) do
    Map.merge(
      %{
        "sender" => %{"id" => @psid},
        "recipient" => %{"id" => @page_id},
        "timestamp" => 1_700_000_000_123
      },
      extra
    )
  end

  defp post_inbound(conn, channel, params) do
    body = Jason.encode!(params)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", InboundSignature.sign_legacy(@app_secret, body))
    |> post(~p"/api/v1/channels/#{channel.id}/inbound", body)
  end

  test "is registered as a duplex built-in with receipts" do
    assert {:ok, Messenger} = Adapter.adapter_for("messenger")
    assert Messenger.supported_modes() == ~w(inbound outbound duplex)
    assert Adapter.capability?("messenger", :receipts)
    assert Adapter.capability?("messenger", :provider_ack)
  end

  describe "config" do
    test "requires the page, tokens and, on signed channels, the app secret" do
      assert {:error, message} = Adapter.validate_config("messenger", %{})
      assert message =~ "page_id"

      config = %{"page_id" => @page_id, "page_access_token" => "t", "verify_token" => "v"}
      assert :ok = Adapter.validate_config("messenger", config)

      assert {:error, message} =
               Adapter.validate_config("messenger", config, require_signature: true)

      assert message =~ "app_secret"

      assert {:error, _} =
               Adapter.validate_config("messenger", %{config | "page_id" => "my-page"})
    end

    test "secrets are encrypted at rest", %{channel: channel} do
      %{rows: [[raw]]} =
        Repo.query!("SELECT config FROM channels WHERE id = $1", [Ecto.UUID.dump!(channel.id)])

      refute raw =~ "page-token"
      assert Channels.get_channel!(channel.id).config["page_access_token"] == "page-token"
    end
  end

  describe "webhook handshake and signature" do
    test "echoes hub.challenge for the right verify token", %{conn: conn, channel: channel} do
      conn =
        get(conn, ~p"/api/v1/channels/#{channel.id}/inbound", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "verify-me",
          "hub.challenge" => "12345"
        })

      assert response(conn, 200) == "12345"

      conn =
        get(build_conn(), ~p"/api/v1/channels/#{channel.id}/inbound", %{
          "hub.verify_token" => "wrong",
          "hub.challenge" => "12345"
        })

      assert response(conn, 403)
    end

    test "rejects a wrong X-Hub-Signature-256", %{conn: conn, channel: channel} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=" <> String.duplicate("0", 64))
        |> post(~p"/api/v1/channels/#{channel.id}/inbound", Jason.encode!(webhook([])))

      assert json_response(conn, 401)
    end
  end

  describe "inbound" do
    test "a text message creates a participant-scoped activity, once", %{
      conn: conn,
      channel: channel
    } do
      params =
        webhook([
          event(%{
            "message" => %{
              "mid" => "m_in-1",
              "text" => "Where is my order?",
              "quick_reply" => %{"payload" => "ORDER"}
            }
          })
        ])

      conn = post_inbound(conn, channel, params)
      assert %{"activity_ids" => [id]} = json_response(conn, 200)

      activity = Repo.get!(Activity, id)
      assert activity.text == "Where is my order?"
      assert activity.sender == @psid
      assert activity.idempotency_key == "m_in-1"
      assert activity.metadata["quick_reply_payload"] == "ORDER"
      assert activity.metadata["messenger_recipient_id"] == @page_id

      conn = post_inbound(build_conn(), channel, params)
      assert %{"duplicates" => 1, "activity_ids" => [^id]} = json_response(conn, 200)
    end

    test "echoes, read receipts and unknown events create nothing", %{
      conn: conn,
      channel: channel
    } do
      params =
        webhook([
          event(%{"message" => %{"mid" => "m_echo", "text" => "ours", "is_echo" => true}}),
          event(%{"read" => %{"watermark" => 1_700_000_000_000}}),
          event(%{"optin" => %{"ref" => "x"}})
        ])

      conn = post_inbound(conn, channel, params)
      assert json_response(conn, 200)["receipts_processed"] == 0
      assert Repo.aggregate(Activity, :count) == 0
    end

    test "postbacks, reactions, edits and unsends", %{channel: channel} do
      params =
        webhook([
          event(%{
            "postback" => %{"title" => "Track order", "payload" => "TRACK", "mid" => "m_pb"}
          }),
          event(%{
            "reaction" => %{
              "mid" => "m_out-1",
              "action" => "react",
              "emoji" => "👍",
              "reaction" => "like"
            }
          }),
          event(%{"message_edit" => %{"mid" => "m_in-1", "text" => "fixed", "num_edit" => 1}}),
          event(%{"message" => %{"mid" => "m_in-2", "is_deleted" => true}})
        ])

      assert {:ok, [postback, reaction, edit, unsend]} = Messenger.parse_inbound(channel, params)

      assert postback["type"] == "message"
      assert postback["text"] == "Track order"
      assert postback["metadata"]["interactive_reply"]["payload"] == "TRACK"
      assert postback["idempotency_key"] == "m_pb"

      assert reaction["type"] == "messageReaction"
      assert reaction["text"] == "👍"
      assert reaction["reply_to_provider_id"] == "m_out-1"

      assert edit["type"] == "messageUpdate"
      assert edit["text"] == "fixed"
      assert edit["reply_to_provider_id"] == "m_in-1"
      assert edit["idempotency_key"] == "m_in-1:edit:1"

      assert unsend["type"] == "messageDelete"
      assert unsend["reply_to_provider_id"] == "m_in-2"
    end

    test "rejects a payload of another object" do
      assert {:error, _} =
               Messenger.parse_inbound(%{config: %{}}, %{"object" => "instagram", "entry" => []})
    end

    test "an image is downloaded from its CDN URL and stored", %{conn: conn, channel: channel} do
      stub_graph(fn conn, _body ->
        conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, @png)
      end)

      params =
        webhook([
          event(%{
            "message" => %{
              "mid" => "m_img",
              "attachments" => [
                %{
                  "type" => "image",
                  "payload" => %{"url" => "https://scontent.xx.fbcdn.net/v/photo.png"}
                }
              ]
            }
          })
        ])

      conn = post_inbound(conn, channel, params)
      assert %{"activity_ids" => [id]} = json_response(conn, 200)

      [attachment] = Repo.get!(Activity, id).attachments
      assert attachment["contentType"] == "image/png"
      assert attachment["contentUrl"] =~ "/api/v1/converger/attachments/"
      assert attachment["channelData"]["provider"] == "messenger"

      assert_received {:graph, "GET", "/v/photo.png", _, _}
    end

    test "a media URL on a private address is not fetched", %{conn: conn, channel: channel} do
      params =
        webhook([
          event(%{
            "message" => %{
              "mid" => "m_ssrf",
              "attachments" => [
                %{"type" => "file", "payload" => %{"url" => "http://metadata.test/latest"}}
              ]
            }
          })
        ])

      conn = post_inbound(conn, channel, params)
      assert %{"activity_ids" => [id]} = json_response(conn, 200)

      [attachment] = Repo.get!(Activity, id).attachments
      refute Map.has_key?(attachment, "contentUrl")
      assert attachment["channelData"]["downloadError"] =~ "blocked_url"
      refute_received {:graph, _, _, _, _}
    end

    test "delivery receipts mark deliveries delivered", %{channel: channel} do
      params = webhook([event(%{"delivery" => %{"mids" => ["m_a", "m_b"], "watermark" => 1}})])

      assert {:ok, [%{"provider_message_id" => "m_a", "status" => "delivered"}, _]} =
               Messenger.parse_status_update(channel, params)

      assert :ignore =
               Messenger.parse_status_update(
                 channel,
                 webhook([event(%{"read" => %{"watermark" => 1}})])
               )
    end
  end

  describe "outbound" do
    test "text with card buttons as quick replies", %{channel: channel} do
      stub_graph(fn conn, _ -> ok_message(conn) end)

      activity =
        activity(
          text: "Pick one",
          attachments: [
            %{
              "contentType" => "application/vnd.converger.card.buttons",
              "content" => %{
                "buttons" => [
                  %{"id" => "yes", "title" => "Yes please"},
                  %{"type" => "openUrl", "title" => "Docs", "value" => "https://example.com"}
                ]
              }
            }
          ]
        )

      assert {:ok, %{provider_message_id: "m_out-" <> _}} =
               Messenger.deliver_activity(channel, activity)

      assert_received {:graph, "POST", "/v26.0/" <> @page_id <> "/messages", _, body}
      body = Jason.decode!(body)
      assert body["recipient"] == %{"id" => @psid}
      assert body["messaging_type"] == "RESPONSE"
      assert body["message"]["text"] == "Pick one\nDocs: https://example.com"

      assert body["message"]["quick_replies"] == [
               %{"content_type" => "text", "title" => "Yes please", "payload" => "yes"}
             ]
    end

    test "a message tag sends outside the 24-hour window", %{channel: channel} do
      stub_graph(fn conn, _ -> ok_message(conn) end)

      Messenger.deliver_activity(
        channel,
        activity(
          text: "Agent here",
          metadata: %{"recipient_id" => @psid, "message_tag" => "HUMAN_AGENT"}
        )
      )

      assert [%{"messaging_type" => "MESSAGE_TAG", "tag" => "HUMAN_AGENT"}] = sent_json_bodies()
    end

    test "a link attachment and a stored upload", %{channel: channel, tenant: tenant} do
      stub_graph(fn conn, _ -> ok_message(conn) end)
      {:ok, stored} = Uploads.create_attachment(tenant.id, {"photo.png", @png})

      activity =
        activity(
          text: "Files",
          attachments: [
            %{"contentType" => "application/pdf", "contentUrl" => "https://example.com/a.pdf"},
            %{
              "contentType" => "image/png",
              "contentUrl" => "/api/v1/converger/attachments/#{stored.id}"
            }
          ]
        )

      assert {:ok, %{meta_message_ids: [_, _, _]}} = Messenger.deliver_activity(channel, activity)

      assert_received {:graph, "POST", _, _, link_body}

      assert %{"message" => %{"attachment" => %{"type" => "file", "payload" => %{"url" => _}}}} =
               Jason.decode!(link_body)

      assert_received {:graph, "POST", _, ["multipart/form-data" <> _], upload_body}
      assert upload_body =~ ~s(name="filedata")
      assert upload_body =~ ~s("type":"image")

      assert_received {:graph, "POST", _, _, text_body}
      assert Jason.decode!(text_body)["message"]["text"] == "Files"
    end

    test "errors are classified", %{channel: channel} do
      respond = fn status, error ->
        stub_graph(fn conn, _ ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => error})
        end)

        {:error, error} = Messenger.deliver_activity(channel, activity(text: "hi"))
        error
      end

      assert %DeliveryError{retryable?: false, reason: "outside_window" <> _} =
               respond.(400, %{"code" => 10, "error_subcode" => 2_018_278})

      assert %DeliveryError{retryable?: true} = respond.(400, %{"code" => 613})
      assert %DeliveryError{retryable?: false} = respond.(400, %{"code" => 100})
      assert %DeliveryError{retryable?: true} = respond.(503, %{"code" => 2})
    end

    test "without a recipient the delivery fails permanently", %{channel: channel} do
      assert {:error, %DeliveryError{retryable?: false}} =
               Messenger.deliver_activity(channel, activity(text: "hi", metadata: %{}))
    end

    test "a reply in an inbound conversation goes to the participant", %{
      conn: conn,
      channel: channel
    } do
      params = webhook([event(%{"message" => %{"mid" => "m_conv", "text" => "hello"}})])
      conn = post_inbound(conn, channel, params)
      %{"activity_ids" => [id]} = json_response(conn, 200)
      inbound = Repo.get!(Activity, id)

      stub_graph(fn conn, _ -> ok_message(conn) end)

      assert {:ok, %{provider_message_id: mid}} =
               Messenger.deliver_activity(
                 channel,
                 activity(conversation_id: inbound.conversation_id, text: "hi", metadata: %{})
               )

      assert [%{"recipient" => %{"id" => @psid}}] = sent_json_bodies()

      # Its delivery receipt finds the delivery by the returned message id.
      {:ok, delivery} =
        Deliveries.create_delivery(%{
          activity_id: inbound.id,
          channel_id: channel.id,
          status: "sent",
          provider_message_id: mid
        })

      conn =
        post_inbound(
          build_conn(),
          channel,
          webhook([event(%{"delivery" => %{"mids" => [mid], "watermark" => 1}})])
        )

      assert json_response(conn, 200)["receipts_processed"] == 1
      assert Deliveries.get_delivery!(delivery.id).status == "delivered"
    end

    test "health probe reads the page", %{channel: channel} do
      stub_graph(fn conn, _ -> Req.Test.json(conn, %{"id" => @page_id}) end)
      assert :ok = Messenger.health_probe(channel)
      assert_received {:graph, "GET", "/v26.0/" <> @page_id, _, _}

      stub_graph(fn conn, _ -> conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{}) end)
      assert {:error, "Messenger API returned 401"} = Messenger.health_probe(channel)
    end
  end

  defp sent_json_bodies do
    receive_bodies([])
  end

  defp receive_bodies(acc) do
    receive do
      {:graph, "POST", _path, _type, body} -> receive_bodies([Jason.decode!(body) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
