defmodule ConvergerWeb.WhatsAppInfobipMediaTest do
  # Global Req stub (config :converger, :whatsapp_req_options): not async.
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures

  alias Converger.Activities.Activity
  alias Converger.{Channels, Repo, Uploads}
  alias Converger.Channels.Adapters.WhatsAppInfobip
  alias Converger.Channels.{DeliveryError, Templates}

  @phone "5511999999999"
  @base_url "https://xyz.api.infobip.com"
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
        name: "infobip-media-#{System.unique_integer([:positive])}",
        type: "whatsapp_infobip",
        mode: "duplex",
        status: "active",
        require_signature: false,
        tenant_id: tenant.id,
        config: %{"base_url" => @base_url, "api_key" => "ib-key", "sender" => "447860099299"}
      })

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:infobip, conn.method, conn.request_path, body, conn.req_headers})

      case conn.request_path do
        "/whatsapp/1/message/template" ->
          Req.Test.json(conn, %{"messages" => [%{"messageId" => "ib-template-1"}]})

        "/whatsapp/1/message/" <> _ ->
          Req.Test.json(conn, %{"messageId" => "ib-#{System.unique_integer([:positive])}"})

        "/whatsapp/1/senders/447860099299/media/" <> _ ->
          Plug.Conn.send_resp(conn, 200, @png)

        "/whatsapp/2/senders/447860099299/templates" ->
          Req.Test.json(conn, %{
            "templates" => [
              %{
                "id" => "1",
                "name" => "welcome",
                "language" => "en",
                "status" => "APPROVED",
                "category" => "MARKETING"
              }
            ]
          })
      end
    end)

    %{tenant: tenant, channel: channel}
  end

  defp activity(attrs) do
    struct(
      Activity,
      Map.merge(%{text: nil, attachments: [], metadata: %{"to" => @phone}}, Map.new(attrs))
    )
  end

  defp requests do
    receive_all([])
  end

  defp receive_all(acc) do
    receive do
      {:infobip, method, path, body, _headers} ->
        decoded = if body == "", do: nil, else: Jason.decode!(body)
        receive_all([{method, path, decoded} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "outbound" do
    test "a template, with body placeholders from Meta-style components", %{channel: channel} do
      template = %{
        "name" => "order_update",
        "language" => "en",
        "components" => [
          %{"type" => "body", "parameters" => [%{"type" => "text", "text" => "42"}]}
        ]
      }

      assert {:ok, %{provider_message_id: "ib-template-1"}} =
               WhatsAppInfobip.deliver_activity(
                 channel,
                 activity(metadata: %{"to" => @phone, "template" => template})
               )

      assert [
               {"POST", "/whatsapp/1/message/template",
                %{
                  "messages" => [
                    %{
                      "from" => "447860099299",
                      "to" => @phone,
                      "content" => %{
                        "templateName" => "order_update",
                        "language" => "en",
                        "templateData" => %{"body" => %{"placeholders" => ["42"]}}
                      }
                    }
                  ]
                }}
             ] = requests()
    end

    test "templateData is passed through as is", %{channel: channel} do
      data = %{
        "body" => %{"placeholders" => ["a"]},
        "header" => %{"type" => "IMAGE", "mediaUrl" => "https://x.example/h.png"}
      }

      assert {:ok, _} =
               WhatsAppInfobip.deliver_activity(
                 channel,
                 activity(
                   metadata: %{
                     "to" => @phone,
                     "template" => %{
                       "name" => "promo",
                       "language" => "en",
                       "templateData" => data
                     }
                   }
                 )
               )

      assert [{_, _, %{"messages" => [%{"content" => %{"templateData" => ^data}}]}}] = requests()
    end

    test "an image link with caption, then an audio", %{channel: channel} do
      attachments = [
        %{"contentType" => "image/jpeg", "contentUrl" => "https://cdn.example.com/a.jpg"},
        %{"contentType" => "audio/ogg", "contentUrl" => "https://cdn.example.com/v.ogg"}
      ]

      assert {:ok, %{infobip_message_ids: [first, _], provider_message_id: first}} =
               WhatsAppInfobip.deliver_activity(
                 channel,
                 activity(text: "look", attachments: attachments)
               )

      assert [
               {"POST", "/whatsapp/1/message/image",
                %{
                  "content" => %{
                    "mediaUrl" => "https://cdn.example.com/a.jpg",
                    "caption" => "look"
                  }
                }},
               {"POST", "/whatsapp/1/message/audio",
                %{"content" => %{"mediaUrl" => "https://cdn.example.com/v.ogg"}}}
             ] = requests()
    end

    test "interactive buttons", %{channel: channel} do
      card = %{
        "contentType" => "application/vnd.converger.card.buttons",
        "content" => %{
          "buttons" => [%{"id" => "y", "title" => "Yes"}, %{"id" => "n", "title" => "No"}]
        }
      }

      assert {:ok, _} =
               WhatsAppInfobip.deliver_activity(
                 channel,
                 activity(text: "Sure?", attachments: [card])
               )

      assert [
               {"POST", "/whatsapp/1/message/interactive/buttons",
                %{
                  "content" => %{
                    "body" => %{"text" => "Sure?"},
                    "action" => %{
                      "buttons" => [%{"type" => "REPLY", "id" => "y", "title" => "Yes"}, _]
                    }
                  }
                }}
             ] = requests()
    end

    test "a file stored on local disk has no URL Infobip can fetch", %{
      tenant: tenant,
      channel: channel
    } do
      {:ok, stored} = Uploads.create_attachment(tenant.id, {"photo.png", @png})

      assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
               WhatsAppInfobip.deliver_activity(
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

      assert reason =~ "no public URL"
      assert requests() == []
    end
  end

  describe "inbound media" do
    defp post_inbound(channel, media_url) do
      body = %{
        "results" => [
          %{
            "from" => @phone,
            "to" => "447860099299",
            "messageId" => "ib-in-#{System.unique_integer([:positive])}",
            "receivedAt" => "2026-10-10T12:00:00.000+0000",
            "message" => %{"type" => "IMAGE", "url" => media_url, "caption" => "receipt"}
          }
        ]
      }

      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/channels/#{channel.id}/inbound", Jason.encode!(body))
    end

    test "an inbound image is downloaded with the API key and stored", %{channel: channel} do
      url = @base_url <> "/whatsapp/1/senders/447860099299/media/abc-123"

      [activity_id] = json_response(post_inbound(channel, url), 200)["activity_ids"]
      assert [attachment] = Repo.get!(Activity, activity_id).attachments
      assert attachment["contentType"] == "image/png"
      assert attachment["contentUrl"] =~ "/api/v1/converger/attachments/"
      assert attachment["channelData"]["providerMediaUrl"] == url

      assert_received {:infobip, "GET", "/whatsapp/1/senders/447860099299/media/abc-123", _,
                       headers}

      assert {"authorization", "App ib-key"} in headers
    end

    test "a media URL on another host is never fetched with the API key", %{channel: channel} do
      [activity_id] =
        json_response(post_inbound(channel, "https://attacker.example/steal"), 200)[
          "activity_ids"
        ]

      assert [attachment] = Repo.get!(Activity, activity_id).attachments
      refute attachment["contentUrl"]
      assert attachment["channelData"]["downloadError"] =~ "host"
      assert requests() == []
    end
  end

  test "GET /api/v1/channels/:id/templates lists the sender's templates", %{
    tenant: tenant,
    channel: channel
  } do
    Templates.invalidate(channel.id)

    conn =
      build_conn()
      |> put_req_header("x-api-key", tenant.api_key)
      |> get("/api/v1/channels/#{channel.id}/templates")

    assert %{"data" => [%{"name" => "welcome", "status" => "APPROVED"}], "cached" => false} =
             json_response(conn, 200)
  end
end
