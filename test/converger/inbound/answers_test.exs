defmodule Converger.Inbound.AnswersTest do
  @moduledoc """
  Answers to actionable messages come back as one shape (#68,
  docs/protocol/messages.md section 6): button / list / keyboard answer keys
  and numeric replies become a `message` with the action's text,
  `metadata.action` and `reply_to_id`.
  """

  use Converger.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Inbound, Repo}
  alias Converger.Activities.Activity
  alias Converger.Channels.RichContent
  alias Converger.Inbound.Answers

  setup do
    tenant = tenant_fixture()
    home = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, home)

    {:ok, telegram} =
      Converger.Channels.create_channel(%{
        name: unique_channel_name(),
        type: "telegram",
        mode: "inbound",
        status: "active",
        tenant_id: tenant.id,
        config: %{"bot_token" => "7000000001:AAFake", "secret_token" => "s3cr3t"}
      })

    %{tenant: tenant, home: home, conversation: conversation, telegram: telegram}
  end

  defp bot_message(ctx, message_type, data, extra \\ %{}) do
    {:ok, activity} =
      Activities.create_activity(%{
        "tenant_id" => ctx.tenant.id,
        "conversation_id" => ctx.conversation.id,
        "sender" => "bot-1",
        "type" => "message",
        "message_type" => message_type,
        "payload" => Map.merge(%{"data" => data}, extra)
      })

    activity
  end

  defp buttons(ctx) do
    bot_message(ctx, "buttons", %{
      "text" => "How can I help?",
      "buttons" => [
        %{"label" => "Track an order", "value" => "/track"},
        %{"label" => "Pricing", "url" => "https://example.com/pricing"},
        %{"label" => "Talk to a human"}
      ]
    })
  end

  defp receive!(ctx, message) do
    message = Map.merge(%{"sender" => "user-1", "type" => "message"}, message)

    assert {:created, activity} =
             Inbound.receive_message(ctx.telegram, message, conversation_id: ctx.conversation.id)

    activity
  end

  defp age!(activity, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    {1, _} =
      Repo.update_all(from(a in Activity, where: a.id == ^activity.id), set: [inserted_at: at])
  end

  describe "answer keys" do
    test "a keyboard press becomes the action's value with metadata.action", ctx do
      offer = buttons(ctx)

      answer =
        receive!(ctx, %{
          "text" => "Track an order",
          "answer" => %{
            "ref" => RichContent.ref(offer.id, 0),
            "source" => "keyboard",
            "label" => "Track an order"
          }
        })

      assert answer.type == "message"
      assert answer.text == "/track"
      assert answer.reply_to_id == offer.id

      assert answer.metadata["action"] == %{
               "label" => "Track an order",
               "value" => "/track",
               "source" => "keyboard"
             }
    end

    test "an action without value answers with its label", ctx do
      offer = buttons(ctx)

      answer =
        receive!(ctx, %{
          "text" => "x",
          "answer" => %{"ref" => RichContent.ref(offer.id, 2), "source" => "button"}
        })

      assert answer.text == "Talk to a human"
      assert answer.metadata["action"]["value"] == "Talk to a human"
    end

    test "non-string interrupt values survive in metadata.action", ctx do
      interrupt =
        bot_message(
          ctx,
          "interrupt",
          %{
            "payload" => %{"title" => "249.90 TRY refund"},
            "actions" => [
              %{"label" => "Approve", "value" => %{"approved" => true}},
              %{"label" => "Reject", "value" => %{"approved" => false}}
            ]
          },
          %{"id" => "approve/0:interrupt#0"}
        )

      answer =
        receive!(ctx, %{
          "text" => "Approve",
          "answer" => %{"ref" => RichContent.ref(interrupt.id, 0), "source" => "button"}
        })

      assert answer.text == "Approve"
      assert answer.reply_to_id == interrupt.id
      assert answer.metadata["action"]["value"] == %{"approved" => true}
    end

    test "a key of another conversation or a link keeps the provider label", ctx do
      offer = buttons(ctx)
      other = conversation_fixture(ctx.tenant, ctx.home)

      assert {:created, answer} =
               Inbound.receive_message(
                 ctx.telegram,
                 %{
                   "sender" => "user-1",
                   "type" => "message",
                   "text" => "",
                   "answer" => %{
                     "ref" => RichContent.ref(offer.id, 0),
                     "source" => "keyboard",
                     "label" => "Track an order"
                   }
                 },
                 conversation_id: other.id
               )

      assert answer.text == "Track an order"
      refute Map.has_key?(answer.metadata, "action")
      assert is_nil(answer.reply_to_id)

      link =
        receive!(ctx, %{
          "text" => "Pricing",
          "answer" => %{"ref" => RichContent.ref(offer.id, 1), "source" => "button"}
        })

      refute Map.has_key?(link.metadata, "action")
    end
  end

  describe "numeric replies" do
    test "pick the numbered action of the latest actionable message", ctx do
      offer = buttons(ctx)
      # A later message without actions does not hide it.
      bot_message(ctx, "image", %{"src" => "https://example.com/a.png"})

      answer = receive!(ctx, %{"text" => " 2 "})

      # Links are not numbered: 2 is the third button.
      assert answer.text == "Talk to a human"
      assert answer.reply_to_id == offer.id
      assert answer.metadata["action"]["source"] == "numeric"
    end

    test "the most recent actionable message wins", ctx do
      buttons(ctx)

      latest =
        bot_message(ctx, "quick-reply", %{
          "text" => "Was this helpful?",
          "actions" => [
            %{"label" => "Yes", "value" => "yes"},
            %{"label" => "No", "value" => "no"}
          ]
        })

      answer = receive!(ctx, %{"text" => "1."})
      assert answer.text == "yes"
      assert answer.reply_to_id == latest.id
    end

    test "out of range, too old or the user's own message stays plain text", ctx do
      offer = buttons(ctx)

      plain = receive!(ctx, %{"text" => "7"})
      assert plain.text == "7"
      assert is_nil(plain.reply_to_id)
      refute Map.has_key?(plain.metadata, "action")

      age!(offer, Answers.window_seconds() + 60)
      old = receive!(ctx, %{"text" => "1"})
      assert old.text == "1"
      refute Map.has_key?(old.metadata, "action")
    end

    test "within the window it still matches", ctx do
      offer = buttons(ctx)
      age!(offer, Answers.window_seconds() - 60)

      answer = receive!(ctx, %{"text" => "1"})
      assert answer.text == "/track"
      assert answer.reply_to_id == offer.id
    end

    test "text that is not a number, or a message with attachments, is untouched", ctx do
      buttons(ctx)

      assert receive!(ctx, %{"text" => "1 please"}).text == "1 please"

      with_file =
        receive!(ctx, %{
          "text" => "1",
          "attachments" => [
            %{"contentType" => "image/png", "contentUrl" => "https://example.com/a.png"}
          ]
        })

      refute Map.has_key?(with_file.metadata, "action")
    end

    test "channels that forward the canonical activity send structured answers", ctx do
      buttons(ctx)

      assert {:created, activity} =
               Inbound.receive_message(
                 ctx.home,
                 %{"sender" => "user-1", "type" => "message", "text" => "1"},
                 conversation_id: ctx.conversation.id
               )

      assert activity.text == "1"
      refute Map.has_key?(activity.metadata, "action")
    end
  end
end
