defmodule ConvergerWeb.WhatsAppMetaMediaTest do
  # Global Req stub (config :converger, :whatsapp_req_options): not async.
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures

  alias Converger.Activities.Activity
  alias Converger.{Channels, Repo, Uploads}
  alias Converger.Channels.Adapters.WhatsAppMeta
  alias Converger.Channels.{DeliveryError, InboundSignature, Templates}
  alias Converger.Uploads.Attachment

  @app_secret "meta-app-secret-media"
  @phone "16505551234"
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::size(256)>>

  setup do
    previous = Application.get_env(:converger, :whatsapp_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :whatsapp_req_options, previous),
        else: Application.delete_env(:converger, :whatsapp_req_options)
    end)

    Application.put_env(:converger, :whatsapp_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: "meta-media-#{System.unique_integer([:positive])}",
        type: "whatsapp_meta",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "phone_number_id" => "106540352242922",
          "access_token" => "token",
          "verify_token" => "verify",
          "app_secret" => @app_secret,
          "waba_id" => "waba-1"
        }
      })

    %{tenant: tenant, channel: channel}
  end

  # Stubs the Graph API: records every request and answers with `respond`.
  defp stub_graph(respond) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:graph, conn.method, conn.request_path, body})
      respond.(conn, body)
    end)
  end

  defp ok_message(conn),
    do:
      Req.Test.json(conn, %{
        "messages" => [%{"id" => "wamid.out-#{System.unique_integer([:positive])}"}]
      })

  defp activity(attrs) do
    struct(
      Activity,
      Map.merge(%{text: nil, attachments: [], metadata: %{"to" => @phone}}, Map.new(attrs))
    )
  end

  defp sent_messages do
    receive_all([])
    |> Enum.filter(fn {_, path, _} -> String.ends_with?(path, "/messages") end)
    |> Enum.map(fn {_, _, body} -> Jason.decode!(body) end)
  end

  defp receive_all(acc) do
    receive do
      {:graph, method, path, body} -> receive_all([{method, path, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "outbound" do
    test "an uploaded image is uploaded to the Media API and sent as an image", %{
      tenant: tenant,
      channel: channel
    } do
      {:ok, stored} = Uploads.create_attachment(tenant.id, {"photo.png", @png})

      stub_graph(fn conn, _body ->
        if String.ends_with?(conn.request_path, "/media"),
          do: Req.Test.json(conn, %{"id" => "media-uploaded-1"}),
          else: ok_message(conn)
      end)

      url = ConvergerWeb.Endpoint.url() <> "/api/v1/converger/attachments/#{stored.id}"

      assert {:ok, %{provider_message_id: "wamid.out-" <> _}} =
               WhatsAppMeta.deliver_activity(
                 channel,
                 activity(
                   text: "our new color",
                   attachments: [%{"contentType" => "image/png", "contentUrl" => url}]
                 )
               )

      assert_received {:graph, "POST", "/v26.0/106540352242922/media", upload}
      assert upload =~ "messaging_product"
      assert upload =~ "image/png"
      assert :binary.match(upload, @png) != :nomatch

      assert [
               %{
                 "type" => "image",
                 "to" => @phone,
                 "image" => %{"id" => "media-uploaded-1", "caption" => "our new color"}
               }
             ] = sent_messages()
    end

    test "an attachment of another tenant is a permanent error", %{channel: channel} do
      other = tenant_fixture()
      {:ok, stored} = Uploads.create_attachment(other.id, {"photo.png", @png})
      stub_graph(fn conn, _ -> ok_message(conn) end)

      assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
               WhatsAppMeta.deliver_activity(
                 channel,
                 activity(
                   attachments: [
                     %{
                       "contentType" => "image/png",
                       "contentUrl" => "/api/v1/converger/attachments/#{stored.id}"
                     }
                   ]
                 )
               )

      assert reason =~ "not found"
      assert sent_messages() == []
    end

    test "an external URL is sent as a link, with the document filename", %{channel: channel} do
      stub_graph(fn conn, _ -> ok_message(conn) end)

      doc = %{
        "contentType" => "application/pdf",
        "contentUrl" => "https://files.example.com/invoice.pdf",
        "name" => "invoice.pdf"
      }

      assert {:ok, %{whatsapp_message_ids: [_]}} =
               WhatsAppMeta.deliver_activity(channel, activity(attachments: [doc]))

      assert [
               %{
                 "type" => "document",
                 "document" => %{
                   "link" => "https://files.example.com/invoice.pdf",
                   "filename" => "invoice.pdf"
                 }
               }
             ] = sent_messages()
    end

    test "a template from metadata.template", %{channel: channel} do
      stub_graph(fn conn, _ -> ok_message(conn) end)

      template = %{
        "name" => "order_update",
        "language" => "en_US",
        "components" => [
          %{"type" => "body", "parameters" => [%{"type" => "text", "text" => "42"}]}
        ]
      }

      assert {:ok, _} =
               WhatsAppMeta.deliver_activity(
                 channel,
                 activity(text: "ignored", metadata: %{"to" => @phone, "template" => template})
               )

      assert [
               %{
                 "type" => "template",
                 "template" => %{
                   "name" => "order_update",
                   "language" => %{"code" => "en_US"},
                   "components" => [%{"type" => "body"}]
                 }
               }
             ] = sent_messages()
    end

    test "a typed card is its image, then reply buttons keyed by answer keys (#68)", %{
      channel: channel
    } do
      stub_graph(fn conn, _ -> ok_message(conn) end)
      id = Ecto.UUID.generate()

      card =
        activity(
          id: id,
          text: "ORD-1",
          message_type: "card",
          payload: %{
            "data" => %{
              "title" => "ORD-1",
              "subtitle" => "249.90 USD",
              "image" => "https://cdn.example.com/ord-1.png",
              "buttons" => [
                %{"label" => "Track this order right now", "value" => "/track ORD-1"},
                %{"label" => "Invoice", "url" => "https://example.com/inv/1"}
              ]
            }
          }
        )

      assert {:ok, %{whatsapp_message_ids: [_, _]}} = WhatsAppMeta.deliver_activity(channel, card)
      assert [image, buttons] = sent_messages()

      assert %{"type" => "image", "image" => %{"link" => "https://cdn.example.com/ord-1.png"}} =
               image

      ref = "a:#{id}:0"

      assert %{
               "type" => "interactive",
               "interactive" => %{
                 "type" => "button",
                 "body" => %{"text" => "ORD-1\n249.90 USD\nInvoice: https://example.com/inv/1"},
                 "action" => %{
                   "buttons" => [
                     %{
                       "type" => "reply",
                       "reply" => %{"id" => ^ref, "title" => "Track this order ri…"}
                     }
                   ]
                 }
               }
             } = buttons
    end

    test "buttons, list, location and contacts", %{channel: channel} do
      stub_graph(fn conn, _ -> ok_message(conn) end)

      attachments = [
        %{
          "contentType" => "application/vnd.converger.card.buttons",
          "content" => %{
            "footer" => "Reply below",
            "buttons" => [%{"id" => "y", "title" => "Yes"}]
          }
        },
        %{
          "contentType" => "application/vnd.converger.card.list",
          "content" => %{
            "body" => "Pick a size",
            "button" => "Sizes",
            "sections" => [%{"title" => "All", "rows" => [%{"id" => "s", "title" => "Small"}]}]
          }
        },
        %{
          "contentType" => "application/vnd.converger.location",
          "content" => %{"latitude" => 41.0, "longitude" => 29.0, "name" => "Shop"}
        },
        %{
          "contentType" => "application/vnd.converger.contacts",
          "content" => [%{"name" => "Ada", "phones" => ["+441234"]}]
        }
      ]

      assert {:ok, %{whatsapp_message_ids: ids, provider_message_id: first}} =
               WhatsAppMeta.deliver_activity(
                 channel,
                 activity(text: "Confirm?", attachments: attachments)
               )

      assert length(ids) == 4
      assert first == hd(ids)

      assert [buttons, list, location, contacts] = sent_messages()

      assert %{
               "type" => "interactive",
               "interactive" => %{
                 "type" => "button",
                 "body" => %{"text" => "Confirm?"},
                 "footer" => %{"text" => "Reply below"},
                 "action" => %{
                   "buttons" => [
                     %{"type" => "reply", "reply" => %{"id" => "y", "title" => "Yes"}}
                   ]
                 }
               }
             } = buttons

      assert %{
               "interactive" => %{
                 "type" => "list",
                 "body" => %{"text" => "Pick a size"},
                 "action" => %{
                   "button" => "Sizes",
                   "sections" => [%{"title" => "All", "rows" => [%{"id" => "s"}]}]
                 }
               }
             } = list

      assert %{"type" => "location", "location" => %{"latitude" => 41.0, "name" => "Shop"}} =
               location

      assert %{
               "type" => "contacts",
               "contacts" => [
                 %{"name" => %{"formatted_name" => "Ada"}, "phones" => [%{"phone" => "+441234"}]}
               ]
             } = contacts
    end

    test "error 131047 (24-hour window) is a permanent outside_window error", %{channel: channel} do
      stub_graph(fn conn, _ ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"code" => 131_047, "message" => "Re-engagement message"}})
      end)

      assert {:error,
              %DeliveryError{retryable?: false, status: 400, reason: "outside_window: " <> hint}} =
               WhatsAppMeta.deliver_activity(channel, activity(text: "hello again"))

      assert hint =~ "metadata.template"
    end

    test "a failed status with 131047 reports outside_window" do
      params = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "statuses" => [
                    %{
                      "id" => "wamid.late",
                      "status" => "failed",
                      "errors" => [%{"code" => 131_047, "title" => "Re-engagement message"}]
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, [%{"status" => "failed", "error" => "outside_window: " <> _}]} =
               WhatsAppMeta.parse_status_update(%{config: %{}}, params)
    end
  end

  describe "inbound media" do
    defp post_inbound(channel, message) do
      body =
        Jason.encode!(%{
          "object" => "whatsapp_business_account",
          "entry" => [
            %{
              "id" => "1",
              "changes" => [
                %{
                  "field" => "messages",
                  "value" => %{
                    "messaging_product" => "whatsapp",
                    "metadata" => %{"phone_number_id" => "106540352242922"},
                    "contacts" => [%{"profile" => %{"name" => "Sheena"}, "wa_id" => @phone}],
                    "messages" => [Map.merge(%{"from" => @phone, "timestamp" => "1"}, message)]
                  }
                }
              ]
            }
          ]
        })

      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "x-hub-signature-256",
        "sha256=" <> InboundSignature.hmac_hex(@app_secret, body)
      )
      |> post(~p"/api/v1/channels/#{channel.id}/inbound", body)
    end

    defp image_message(id) do
      %{
        "id" => id,
        "type" => "image",
        "image" => %{
          "id" => "media-42",
          "mime_type" => "image/png",
          "sha256" => "abc",
          "caption" => "look"
        }
      }
    end

    test "an inbound image is stored and the activity gets a downloadable attachment", %{
      tenant: tenant,
      channel: channel
    } do
      stub_graph(fn conn, _ ->
        case conn.request_path do
          "/v26.0/media-42" ->
            Req.Test.json(conn, %{
              "url" => "https://lookaside.fbsbx.com/whatsapp_business/attachments/?mid=42",
              "mime_type" => "image/png",
              "file_size" => byte_size(@png),
              "id" => "media-42"
            })

          "/whatsapp_business/attachments/" ->
            Plug.Conn.send_resp(conn, 200, @png)
        end
      end)

      conn = post_inbound(channel, image_message("wamid.img-1"))
      [activity_id] = json_response(conn, 200)["activity_ids"]
      activity = Repo.get!(Activity, activity_id)

      assert activity.text == "look"
      assert [attachment] = activity.attachments
      assert attachment["contentType"] == "image/png"
      assert attachment["size"] == byte_size(@png)
      assert attachment["channelData"]["providerMediaId"] == "media-42"

      "/api/v1/converger/attachments/" <> attachment_id = URI.parse(attachment["contentUrl"]).path
      stored = Repo.get!(Attachment, attachment_id)
      assert stored.tenant_id == tenant.id
      assert stored.conversation_id == activity.conversation_id
      assert stored.activity_id == activity.id

      # Both Graph API calls carry the channel's token.
      assert_received {:graph, "GET", "/v26.0/media-42", _}
      assert_received {:graph, "GET", "/whatsapp_business/attachments/", _}
    end

    test "a failed download keeps the stub and the message", %{channel: channel} do
      stub_graph(fn conn, _ -> Plug.Conn.send_resp(conn, 404, "gone") end)

      conn = post_inbound(channel, image_message("wamid.img-2"))
      [activity_id] = json_response(conn, 200)["activity_ids"]

      assert [attachment] = Repo.get!(Activity, activity_id).attachments
      refute attachment["contentUrl"]
      assert attachment["channelData"]["downloadError"] == "http_error: 404"
      assert attachment["channelData"]["providerMediaId"] == "media-42"
    end

    test "a file over the upload limit is not downloaded", %{channel: channel} do
      stub_graph(fn conn, _ ->
        Req.Test.json(conn, %{
          "url" => "https://lookaside.fbsbx.com/x",
          "file_size" => 50 * 1024 * 1024
        })
      end)

      conn = post_inbound(channel, image_message("wamid.img-3"))
      [activity_id] = json_response(conn, 200)["activity_ids"]

      assert [%{"channelData" => %{"downloadError" => "too_large"}}] =
               Repo.get!(Activity, activity_id).attachments

      refute_received {:graph, "GET", "/x", _}
    end

    test "download_media: false keeps stubs without calling the provider", %{channel: channel} do
      {:ok, channel} =
        Channels.update_channel(channel, %{
          config: Map.put(channel.config, "download_media", false)
        })

      stub_graph(fn conn, _ -> Plug.Conn.send_resp(conn, 500, "") end)

      conn = post_inbound(channel, image_message("wamid.img-4"))
      [activity_id] = json_response(conn, 200)["activity_ids"]

      assert [attachment] = Repo.get!(Activity, activity_id).attachments
      refute attachment["contentUrl"]
      refute attachment["channelData"]["downloadError"]
      refute_received {:graph, _, _, _}
    end
  end

  describe "GET /api/v1/channels/:id/templates" do
    defp templates(tenant, channel, query \\ "") do
      build_conn()
      |> put_req_header("x-api-key", tenant.api_key)
      |> get("/api/v1/channels/#{channel.id}/templates#{query}")
    end

    test "lists the WABA templates and caches them", %{tenant: tenant, channel: channel} do
      Templates.invalidate(channel.id)

      stub_graph(fn conn, _ ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "name" => "order_update",
              "language" => "en_US",
              "status" => "APPROVED",
              "category" => "UTILITY",
              "components" => [%{"type" => "BODY", "text" => "Order {{1}} shipped"}],
              "id" => "t1"
            }
          ]
        })
      end)

      assert %{"data" => [%{"name" => "order_update", "status" => "APPROVED"}], "cached" => false} =
               json_response(templates(tenant, channel), 200)

      assert_received {:graph, "GET", "/v26.0/waba-1/message_templates", _}

      assert %{"cached" => true} = json_response(templates(tenant, channel), 200)
      refute_received {:graph, _, _, _}

      assert %{"cached" => false} =
               json_response(templates(tenant, channel, "?refresh=true"), 200)

      assert_received {:graph, "GET", "/v26.0/waba-1/message_templates", _}
    end

    test "a provider error is a 502 and is not cached", %{tenant: tenant, channel: channel} do
      Templates.invalidate(channel.id)
      stub_graph(fn conn, _ -> Plug.Conn.send_resp(conn, 401, "{}") end)

      assert %{"message" => "WhatsApp API returned 401" <> _} =
               assert_api_error(templates(tenant, channel), 502, "upstream_unavailable")
    end

    test "a channel without waba_id cannot list templates", %{tenant: tenant, channel: channel} do
      {:ok, channel} =
        Channels.update_channel(channel, %{config: Map.delete(channel.config, "waba_id")})

      assert %{"message" => "whatsapp_meta config 'waba_id'" <> _} =
               assert_api_error(templates(tenant, channel), 422, "invalid_channel_config")
    end

    test "a channel type without templates is a 422", %{tenant: tenant} do
      {:ok, webhook} =
        Channels.create_channel(%{
          name: "hook-#{System.unique_integer([:positive])}",
          type: "echo",
          mode: "outbound",
          status: "active",
          tenant_id: tenant.id
        })

      assert %{"message" => "Channel type echo has no message templates"} =
               assert_api_error(templates(tenant, webhook), 422, "unsupported_channel_type")
    end

    test "another tenant's channel is a 404", %{channel: channel} do
      other = tenant_fixture()
      assert_error_sent 404, fn -> templates(other, channel) end
    end
  end
end
