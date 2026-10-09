defmodule Converger.Activities.RichActivityTest do
  use Converger.DataCase

  import Ecto.Query
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.Activities
  alias Converger.Activities.{Activity, ActivityAttachment, Downgrade, Serializer}

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp attrs(tenant, conversation, extra) do
    Map.merge(
      %{
        "tenant_id" => tenant.id,
        "conversation_id" => conversation.id,
        "sender" => "user-1",
        "type" => "message",
        "text" => "hi"
      },
      extra
    )
  end

  defp create(tenant, conversation, extra, opts \\ []),
    do: Activities.create_activity(attrs(tenant, conversation, extra), opts)

  defp errors_on_create(result) do
    assert {:error, %Ecto.Changeset{} = changeset} = result
    errors_on(changeset)
  end

  describe "activity types" do
    test "the vocabulary is enumerated" do
      assert Activity.types() ==
               ~w(message event typing messageReaction messageUpdate messageDelete
                  conversationUpdate endOfConversation deliveryReceipt)

      assert Activity.internal_types() == ["deliveryReceipt"]
      refute "deliveryReceipt" in Activity.client_types()
    end

    test "an unknown type is rejected", %{tenant: tenant, conversation: conversation} do
      assert %{type: ["is invalid"]} =
               errors_on_create(create(tenant, conversation, %{"type" => "sticker"}))
    end

    test "internal types are rejected unless created internally", %{
      tenant: tenant,
      conversation: conversation
    } do
      assert %{type: ["is invalid"]} =
               errors_on_create(create(tenant, conversation, %{"type" => "deliveryReceipt"}))

      assert {:ok, %Activity{type: "deliveryReceipt"}} =
               create(tenant, conversation, %{"type" => "deliveryReceipt"}, internal: true)

      assert {:error, %Ecto.Changeset{}} =
               Activities.create_client_activity(
                 %{"type" => "deliveryReceipt", "internal" => true},
                 %{tenant_id: tenant.id, conversation_id: conversation.id, sender: "u"}
               )
    end
  end

  describe "attachments" do
    test "an attachment without contentType is rejected", %{
      tenant: tenant,
      conversation: conversation
    } do
      result =
        create(tenant, conversation, %{
          "attachments" => [%{"contentUrl" => "https://example.com/a.png", "name" => "a.png"}]
        })

      assert %{attachments: ["attachment 0: contentType can't be blank"]} =
               errors_on_create(result)
    end

    test "rejects unsafe URLs, non-MIME content types and card attachments without content",
         %{tenant: tenant, conversation: conversation} do
      result =
        create(tenant, conversation, %{
          "attachments" => [
            %{"contentType" => "image/png", "contentUrl" => "javascript:alert(1)"},
            %{"contentType" => "not a mime type"},
            %{"contentType" => "application/vnd.converger.card.hero"},
            %{"contentType" => "image/png", "size" => -1}
          ]
        })

      errors = errors_on_create(result).attachments
      assert "attachment 0: contentUrl must be an http(s) URL or an absolute path" in errors
      assert "attachment 1: contentType must be a MIME type" in errors

      assert "attachment 2: content is required (an object) for card attachments" in errors
      assert "attachment 3: size must be greater than or equal to 0" in errors
    end

    test "valid attachments are normalised: unknown keys dropped, channelData kept", %{
      tenant: tenant,
      conversation: conversation
    } do
      {:ok, activity} =
        create(tenant, conversation, %{
          "attachments" => [
            %{
              "contentType" => "image/png",
              "contentUrl" => "/api/v1/converger/attachments/abc",
              "name" => "a.png",
              "size" => 12,
              "thumbnailUrl" => "https://cdn.example.com/a-thumb.png",
              "channelData" => %{"providerMediaId" => "m-1"},
              "unexpected" => "dropped"
            },
            %{
              "contentType" => "application/vnd.converger.card.hero",
              "content" => %{"title" => "ORD-1"}
            }
          ]
        })

      assert activity.attachments == [
               %{
                 "contentType" => "image/png",
                 "contentUrl" => "/api/v1/converger/attachments/abc",
                 "name" => "a.png",
                 "size" => 12,
                 "thumbnailUrl" => "https://cdn.example.com/a-thumb.png",
                 "channelData" => %{"providerMediaId" => "m-1"}
               },
               %{
                 "contentType" => "application/vnd.converger.card.hero",
                 "content" => %{"title" => "ORD-1"}
               }
             ]
    end

    test "attachments stored before the schema (no contentType) still load and serialise", %{
      tenant: tenant,
      conversation: conversation
    } do
      activity = activity_fixture(tenant, conversation)
      legacy = [%{"url" => "https://example.com/old.png", "provider" => "legacy"}]

      from(a in Activity, where: a.id == ^activity.id)
      |> Repo.update_all(set: [attachments: legacy])

      reloaded = Repo.reload!(activity)
      assert reloaded.attachments == legacy
      assert Serializer.canonical(reloaded).attachments == legacy
    end

    test "ActivityAttachment.normalize/1 rejects non-object content" do
      assert {:error, changeset} =
               ActivityAttachment.normalize(%{"contentType" => "text/plain", "content" => 1})

      assert %{content: ["must be an object or a list"]} = errors_on(changeset)
    end
  end

  describe "replies" do
    test "a message may reply to a message of the same conversation", %{
      tenant: tenant,
      conversation: conversation
    } do
      original = activity_fixture(tenant, conversation)
      {:ok, reply} = create(tenant, conversation, %{"reply_to_id" => original.id})

      assert reply.reply_to_id == original.id
      assert Serializer.canonical(reply).reply_to_id == original.id
    end

    test "a reference to another conversation or to nothing is rejected", %{
      tenant: tenant,
      channel: channel,
      conversation: conversation
    } do
      other = activity_fixture(tenant, conversation_fixture(tenant, channel))

      assert %{reply_to_id: ["does not exist in this conversation"]} =
               errors_on_create(create(tenant, conversation, %{"reply_to_id" => other.id}))

      assert %{reply_to_id: ["does not exist in this conversation"]} =
               errors_on_create(
                 create(tenant, conversation, %{"reply_to_id" => Ecto.UUID.generate()})
               )

      assert %{reply_to_id: ["is invalid"]} =
               errors_on_create(create(tenant, conversation, %{"reply_to_id" => "nope"}))
    end

    test "the reply_to_id index is a valid partitioned index on every partition" do
      %{rows: [[valid, kind]]} =
        Repo.query!("""
        SELECT i.indisvalid, c.relkind::text
        FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        WHERE i.indexrelid = to_regclass('activities_reply_to_id_index')
        """)

      assert valid
      assert kind == "I"
    end

    test "a rejected reference does not consume a seq", %{
      tenant: tenant,
      conversation: conversation
    } do
      _first = activity_fixture(tenant, conversation)

      assert {:error, _} =
               create(tenant, conversation, %{"reply_to_id" => Ecto.UUID.generate()})

      assert {:ok, %{seq: 2}} = create(tenant, conversation, %{})
    end
  end

  describe "reactions" do
    test "require reply_to_id and reference a message", %{
      tenant: tenant,
      conversation: conversation
    } do
      assert %{reply_to_id: ["is required for messageReaction"]} =
               errors_on_create(
                 create(tenant, conversation, %{"type" => "messageReaction", "text" => "👍"})
               )

      original = activity_fixture(tenant, conversation)

      {:ok, reaction} =
        create(tenant, conversation, %{
          "type" => "messageReaction",
          "text" => "👍",
          "sender" => "someone-else",
          "reply_to_id" => original.id
        })

      assert reaction.reply_to_id == original.id

      assert %{reply_to_id: ["must reference a message"]} =
               errors_on_create(
                 create(tenant, conversation, %{
                   "type" => "messageReaction",
                   "text" => "👍",
                   "reply_to_id" => reaction.id
                 })
               )
    end
  end

  describe "edits and deletes" do
    setup %{tenant: tenant, conversation: conversation} do
      %{original: activity_fixture(tenant, conversation, %{text: "teh typo"})}
    end

    test "messageUpdate stamps edited_at on the original and keeps its content", %{
      tenant: tenant,
      conversation: conversation,
      original: original
    } do
      {:ok, update} =
        create(tenant, conversation, %{
          "type" => "messageUpdate",
          "text" => "the typo",
          "reply_to_id" => original.id
        })

      original = Repo.reload!(original)
      assert original.edited_at == update.inserted_at
      assert original.text == "teh typo"
      assert is_nil(original.deleted_at)
      assert Serializer.canonical(original).edited_at == update.inserted_at
    end

    test "messageUpdate needs new content", %{
      tenant: tenant,
      conversation: conversation,
      original: original
    } do
      assert %{text: [_]} =
               errors_on_create(
                 create(tenant, conversation, %{
                   "type" => "messageUpdate",
                   "text" => " ",
                   "reply_to_id" => original.id
                 })
               )
    end

    test "only the original sender may edit or delete", %{
      tenant: tenant,
      conversation: conversation,
      original: original
    } do
      for type <- ~w(messageUpdate messageDelete) do
        result =
          create(tenant, conversation, %{
            "type" => type,
            "sender" => "intruder",
            "reply_to_id" => original.id
          })

        assert %{reply_to_id: [message]} = errors_on_create(result)
        assert message =~ "sender's own messages"
      end

      assert is_nil(Repo.reload!(original).edited_at)
    end

    test "messageDelete stamps deleted_at; a deleted message cannot be edited or deleted again",
         %{tenant: tenant, conversation: conversation, original: original} do
      {:ok, delete} =
        create(tenant, conversation, %{"type" => "messageDelete", "reply_to_id" => original.id})

      assert Repo.reload!(original).deleted_at == delete.inserted_at

      for type <- ~w(messageUpdate messageDelete) do
        assert %{reply_to_id: ["references a deleted message"]} =
                 errors_on_create(
                   create(tenant, conversation, %{"type" => type, "reply_to_id" => original.id})
                 )
      end
    end
  end

  describe "downgrade plan" do
    defp activity(type, text, sender \\ "user-1"),
      do: %Activity{type: type, text: text, sender: sender, attachments: []}

    test "native types pass through" do
      assert :native == Downgrade.plan(activity("messageReaction", "👍"), %{type: "webhook"})
      assert :native == Downgrade.plan(activity("message", "hi"), %{type: "whatsapp_meta"})
    end

    test "unsupported types become text messages" do
      channel = %{type: "whatsapp_meta", config: %{}}

      assert {:downgrade, %Activity{type: "message", text: "user-1 reacted with 👍"}} =
               Downgrade.plan(activity("messageReaction", "👍"), channel)

      assert {:downgrade, %Activity{text: "(edited) fixed"}} =
               Downgrade.plan(activity("messageUpdate", "fixed"), channel)

      assert {:downgrade, %Activity{text: "user-1 deleted a message"}} =
               Downgrade.plan(activity("messageDelete", nil), channel)

      assert {:downgrade, %Activity{text: "order shipped"}} =
               Downgrade.plan(activity("event", "order shipped"), channel)
    end

    test "types without text, internal types and the skip policy are skipped" do
      channel = %{type: "whatsapp_meta", config: %{}}

      assert :skip == Downgrade.plan(activity("typing", nil), channel)
      assert :skip == Downgrade.plan(activity("messageReaction", nil), channel)
      assert :skip == Downgrade.plan(activity("event", ""), channel)
      assert :skip == Downgrade.plan(activity("deliveryReceipt", "x"), %{type: "webhook"})

      skip = %{type: "whatsapp_meta", config: %{"unsupported_activities" => "skip"}}
      assert :skip == Downgrade.plan(activity("messageReaction", "👍"), skip)
    end

    test "the channel config only accepts known policies", %{tenant: tenant} do
      assert {:error, changeset} =
               Converger.Channels.create_channel(%{
                 name: unique_channel_name(),
                 type: "echo",
                 mode: "outbound",
                 status: "active",
                 tenant_id: tenant.id,
                 config: %{"unsupported_activities" => "explode"}
               })

      assert %{config: ["unsupported_activities must be one of: downgrade, skip"]} =
               errors_on(changeset)
    end
  end

  describe "delivery of unsupported types" do
    setup %{tenant: tenant} do
      echo = channel_fixture(tenant, %{type: "echo"})
      %{echo: echo, echo_conversation: conversation_fixture(tenant, echo)}
    end

    defp echo_replies(conversation) do
      from(a in Activity,
        where: a.conversation_id == ^conversation.id and a.sender == "bot",
        select: a.text
      )
      |> Repo.all()
    end

    test "a reaction reaches a message-only channel as text", %{
      tenant: tenant,
      echo_conversation: conversation
    } do
      original = activity_fixture(tenant, conversation, %{text: "hello"})

      {:ok, _} =
        create(tenant, conversation, %{
          "type" => "messageReaction",
          "text" => "👍",
          "reply_to_id" => original.id
        })

      assert echo_replies(conversation) == ["hello", "user-1 reacted with 👍"]
    end

    test "typing is never delivered to a message-only channel", %{
      tenant: tenant,
      echo_conversation: conversation
    } do
      {:ok, typing} = create(tenant, conversation, %{"type" => "typing", "text" => nil})

      assert echo_replies(conversation) == []
      assert Converger.Pipeline.resolve_delivery_channels(typing) == []
    end

    test "with unsupported_activities: skip the channel gets no delivery", %{tenant: tenant} do
      echo =
        channel_fixture(tenant, %{type: "echo", config: %{"unsupported_activities" => "skip"}})

      conversation = conversation_fixture(tenant, echo)
      original = activity_fixture(tenant, conversation, %{text: "hello"})

      {:ok, reaction} =
        create(tenant, conversation, %{
          "type" => "messageReaction",
          "text" => "👍",
          "reply_to_id" => original.id
        })

      assert Converger.Pipeline.resolve_delivery_channels(reaction) == []
      assert echo_replies(conversation) == ["hello"]
    end
  end
end
