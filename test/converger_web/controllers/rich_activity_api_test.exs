defmodule ConvergerWeb.RichActivityApiTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Channels, Deliveries, Repo}
  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias Converger.Channels.InboundSignature

  @app_secret "meta-app-secret-rich"
  @phone "16505551234"

  defp api_conn(channel, conversation) do
    {:ok, token, _} = ConvergerToken.generate_conversation_token(channel, conversation.id)

    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp tenant_conn(tenant), do: put_req_header(build_conn(), "x-api-key", tenant.api_key)

  describe "Converger API validation" do
    setup do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel)
      %{tenant: tenant, channel: channel, conversation: conversation}
    end

    defp post_activity(channel, conversation, body) do
      channel
      |> api_conn(conversation)
      |> post(~p"/api/v1/converger/conversations/#{conversation.id}/activities", body)
    end

    test "an unknown type is rejected with 422", %{channel: channel, conversation: conversation} do
      conn = post_activity(channel, conversation, %{"type" => "sticker", "text" => "hi"})
      assert %{"errors" => %{"type" => ["is invalid"]}} = json_response(conn, 422)
    end

    test "internal types cannot be sent by clients", %{
      channel: channel,
      conversation: conversation
    } do
      conn = post_activity(channel, conversation, %{"type" => "deliveryReceipt"})
      assert %{"errors" => %{"type" => ["is invalid"]}} = json_response(conn, 422)
    end

    test "an attachment without contentType is rejected with 422", %{
      channel: channel,
      conversation: conversation
    } do
      conn =
        post_activity(channel, conversation, %{
          "text" => "see attached",
          "attachments" => [%{"contentUrl" => "https://example.com/a.png"}]
        })

      assert %{"errors" => %{"attachments" => ["attachment 0: contentType can't be blank"]}} =
               json_response(conn, 422)
    end

    test "replyToId round-trips, edits and deletes are listed with markers", %{
      channel: channel,
      conversation: conversation
    } do
      original_id =
        json_response(post_activity(channel, conversation, %{"text" => "helo"}), 200)["id"]

      reply_id =
        post_activity(channel, conversation, %{"text" => "reply", "replyToId" => original_id})
        |> json_response(200)
        |> Map.fetch!("id")

      update =
        post_activity(channel, conversation, %{
          "type" => "messageUpdate",
          "text" => "hello",
          "replyToId" => original_id
        })

      assert json_response(update, 200)["id"]

      missing_target = post_activity(channel, conversation, %{"type" => "messageDelete"})

      assert %{"errors" => %{"reply_to_id" => ["is required for messageDelete"]}} =
               json_response(missing_target, 422)

      conn =
        channel
        |> api_conn(conversation)
        |> get(~p"/api/v1/converger/conversations/#{conversation.id}/activities")

      activities = json_response(conn, 200)["activities"]
      by_id = Map.new(activities, &{&1["id"], &1})

      assert by_id[reply_id]["replyToId"] == original_id
      assert by_id[original_id]["editedAt"]
      assert is_nil(by_id[original_id]["deletedAt"])
      assert by_id[original_id]["text"] == "helo"

      assert [%{"type" => "messageUpdate", "text" => "hello", "replyToId" => ^original_id}] =
               Enum.filter(activities, &(&1["type"] == "messageUpdate"))

      # The published JSON Schema describes what the API returns.
      root = Converger.ProtocolSchemas.build!("activity.schema.json")

      for activity <- activities,
          do: assert(:ok == Converger.ProtocolSchemas.validate(activity, root))
    end

    test "the published attachment schema agrees with the server's validation" do
      root =
        JSV.build!(
          %{
            "$ref" =>
              Converger.ProtocolSchemas.base_uri() <> "activity.schema.json#/$defs/attachment"
          },
          resolver: [Converger.ProtocolSchemas, JSV.Resolver.Embedded]
        )

      valid = %{
        "contentType" => "application/vnd.converger.card.hero",
        "content" => %{"title" => "ORD-1"},
        "contentUrl" => "/api/v1/converger/attachments/abc"
      }

      invalid = [
        %{"contentUrl" => "https://example.com/a.png"},
        %{"contentType" => "application/vnd.converger.card.hero"},
        %{"contentType" => "image/png", "contentUrl" => "javascript:alert(1)"}
      ]

      assert {:ok, _} = Activities.ActivityAttachment.normalize(valid)
      assert :ok == Converger.ProtocolSchemas.validate(valid, root)

      for attachment <- invalid do
        assert {:error, _} = Activities.ActivityAttachment.normalize(attachment)
        assert {:error, _} = Converger.ProtocolSchemas.validate(attachment, root)
      end
    end

    test "the tenant REST API rejects unknown types too", %{
      tenant: tenant,
      conversation: conversation
    } do
      conn =
        tenant
        |> tenant_conn()
        |> post(~p"/api/v1/conversations/#{conversation.id}/activities", %{"type" => "nope"})

      assert %{"errors" => %{"type" => ["is invalid"]}} = json_response(conn, 422)
    end
  end

  describe "WhatsApp reactions" do
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

      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        wamid = "wamid.out-#{System.unique_integer([:positive])}"
        send(test_pid, {:whatsapp_request, Jason.decode!(body), wamid})
        Req.Test.json(conn, %{"messages" => [%{"id" => wamid}]})
      end)

      tenant = tenant_fixture()

      {:ok, meta} =
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
            "app_secret" => @app_secret
          }
        })

      %{tenant: tenant, meta: meta}
    end

    defp inbound(meta, message) do
      params = %{
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
      }

      body = Jason.encode!(params)
      signature = "sha256=" <> InboundSignature.hmac_hex(@app_secret, body)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", signature)
        |> post(~p"/api/v1/channels/#{meta.id}/inbound", body)

      [activity_id] = json_response(conn, 200)["activity_ids"]
      Repo.get!(Activity, activity_id)
    end

    defp reaction(id, message_id, emoji \\ "👍") do
      %{
        "id" => id,
        "type" => "reaction",
        "reaction" => %{"message_id" => message_id, "emoji" => emoji}
      }
    end

    test "a reaction to an outbound message arrives as messageReaction referencing it", %{
      tenant: tenant,
      meta: meta
    } do
      user_message =
        inbound(meta, %{"id" => "wamid.in-1", "type" => "text", "text" => %{"body" => "hi"}})

      conn =
        tenant
        |> tenant_conn()
        |> post(~p"/api/v1/conversations/#{user_message.conversation_id}/activities", %{
          "text" => "Your order shipped",
          "sender" => "bot"
        })

      bot_id = json_response(conn, 201)["data"]["id"]
      assert_receive {:whatsapp_request, %{"text" => %{"body" => "Your order shipped"}}, wamid}
      assert Deliveries.get_delivery_by_provider_message_id(meta.id, wamid)

      reacted = inbound(meta, reaction("wamid.in-2", wamid))

      assert reacted.type == "messageReaction"
      assert reacted.reply_to_id == bot_id
      assert reacted.text == "👍"
      assert reacted.conversation_id == user_message.conversation_id
      assert reacted.metadata["reaction"] == %{"message_id" => wamid, "emoji" => "👍"}

      # The user's own reaction is not echoed back to WhatsApp.
      refute_receive {:whatsapp_request, _, _}
    end

    test "a reaction to an inbound message references it; an unknown target stays an event",
         %{meta: meta} do
      user_message =
        inbound(meta, %{"id" => "wamid.in-3", "type" => "text", "text" => %{"body" => "hi"}})

      reacted = inbound(meta, reaction("wamid.in-4", "wamid.in-3", "❤️"))
      assert reacted.type == "messageReaction"
      assert reacted.reply_to_id == user_message.id

      unknown = inbound(meta, reaction("wamid.in-5", "wamid.before-converger"))
      assert unknown.type == "event"
      assert is_nil(unknown.reply_to_id)
      assert unknown.metadata["reaction"]["message_id"] == "wamid.before-converger"
    end

    test "a WhatsApp reply references the original message", %{meta: meta} do
      original =
        inbound(meta, %{"id" => "wamid.in-6", "type" => "text", "text" => %{"body" => "a"}})

      reply =
        inbound(meta, %{
          "id" => "wamid.in-7",
          "type" => "text",
          "text" => %{"body" => "b"},
          "context" => %{"id" => "wamid.in-6"}
        })

      assert reply.type == "message"
      assert reply.reply_to_id == original.id
    end

    test "a bot reaction is downgraded to text for WhatsApp, or skipped per channel", %{
      tenant: tenant,
      meta: meta
    } do
      user_message =
        inbound(meta, %{"id" => "wamid.in-8", "type" => "text", "text" => %{"body" => "thanks"}})

      react = fn ->
        tenant
        |> tenant_conn()
        |> post(~p"/api/v1/conversations/#{user_message.conversation_id}/activities", %{
          "type" => "messageReaction",
          "text" => "🙏",
          "sender" => "bot",
          "reply_to_id" => user_message.id
        })
        |> json_response(201)
      end

      react.()
      assert_receive {:whatsapp_request, %{"text" => %{"body" => "bot reacted with 🙏"}}, _}

      {:ok, _} =
        Channels.update_channel(meta, %{
          config: Map.put(meta.config, "unsupported_activities", "skip")
        })

      %{"data" => %{"id" => id}} = react.()
      refute_receive {:whatsapp_request, _, _}
      assert Activities.get_activity!(id).type == "messageReaction"
    end
  end
end
