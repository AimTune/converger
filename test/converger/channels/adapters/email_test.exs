defmodule Converger.Channels.Adapters.EmailTest do
  use Converger.DataCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.Channels.{Adapter, DeliveryError}
  alias Converger.Channels.Adapters.Email
  alias Converger.Uploads

  @config %{
    "provider" => "postmark",
    "from" => "ACME Support <support@acme.test>",
    "api_key" => "pm-token",
    "inbound_secret" => "s3cret"
  }

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant, %{type: "email", config: @config})
    # The conversation lives on another channel, as when an agent replies by
    # email to a web chat; activities created in it are not sent by email.
    conversation = conversation_fixture(tenant, channel_fixture(tenant))
    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  describe "registry and config" do
    test "is a built-in duplex type" do
      assert {:ok, Email} = Adapter.adapter_for("email")
      assert Email.supported_modes() == ~w(inbound outbound duplex)
      assert Adapter.capability?("email", :provider_ack)
    end

    test "accepts a valid config" do
      assert Adapter.validate_config("email", @config) == :ok

      assert Adapter.validate_config("email", %{
               "provider" => "ses",
               "from" => "a@acme.test",
               "aws_region" => "eu-west-1",
               "aws_access_key_id" => "AKIA",
               "aws_access_key_secret" => "x",
               "ses_topic_arn" => "arn:aws:sns:eu-west-1:1:inbound"
             }) == :ok
    end

    test "rejects invalid configs" do
      assert {:error, msg} = Adapter.validate_config("email", Map.put(@config, "provider", "fax"))
      assert msg =~ "provider"

      assert {:error, msg} = Adapter.validate_config("email", Map.put(@config, "from", "nobody"))
      assert msg =~ "from"

      assert {:error, msg} = Adapter.validate_config("email", Map.delete(@config, "api_key"))
      assert msg =~ "api_key"

      assert {:error, msg} =
               Adapter.validate_config("email", Map.put(@config, "inbound_provider", "ses"))

      assert msg =~ "ses_topic_arn"

      assert {:error, msg} =
               Adapter.validate_config("email", %{
                 "provider" => "mailgun",
                 "from" => "a@acme.test",
                 "api_key" => "k",
                 "mailgun_domain" => "mg.acme.test",
                 "mailgun_signing_secret" => "x",
                 "mailgun_region" => "mars"
               })

      assert msg =~ "mailgun_region"
    end

    test "guards the SMTP host against private targets" do
      config = %{"provider" => "smtp", "from" => "a@acme.test", "smtp_host" => "127.0.0.1"}
      assert {:error, msg} = Adapter.validate_config("email", config)
      assert msg =~ "smtp_host"
    end

    test "the inbound provider defaults to the outbound one, rfc822 for smtp" do
      assert Email.inbound_provider(%{"provider" => "sendgrid"}) == "sendgrid"
      assert Email.inbound_provider(%{"provider" => "smtp"}) == "rfc822"

      assert Email.inbound_provider(%{"provider" => "smtp", "inbound_provider" => "mailgun"}) ==
               "mailgun"
    end
  end

  describe "deliver_activity/2" do
    test "sends a new email with a deterministic Message-ID", ctx do
      activity =
        activity_fixture(ctx.tenant, ctx.conversation, %{
          text: "Hello <there>\nsecond line",
          metadata: %{"email_to" => "Jane <Jane@Example.com>"}
        })

      assert {:ok, meta} = Email.deliver_activity(ctx.channel, activity)
      message_id = "converger.#{activity.id}@acme.test"
      assert meta == %{provider_message_id: message_id, email_message_id: message_id}

      assert_received {:email, email}
      assert email.to == [{"", "jane@example.com"}]
      assert email.from == {"ACME Support", "support@acme.test"}
      assert email.subject == "New message"
      assert email.headers["Message-ID"] == "<#{message_id}>"
      refute Map.has_key?(email.headers, "In-Reply-To")
      assert email.text_body == "Hello <there>\nsecond line"
      assert email.html_body =~ "Hello &lt;there&gt;<br>"
    end

    test "a typed buttons message is a numbered list with links, in text and HTML (#68)", ctx do
      activity =
        activity_fixture(ctx.tenant, ctx.conversation, %{
          message_type: "buttons",
          payload: %{
            "data" => %{
              "text" => "How can I help?",
              "buttons" => [
                %{"label" => "Track an order", "value" => "/track"},
                %{"label" => "Pricing", "url" => "https://example.com/pricing"},
                %{"label" => "Talk to a human"}
              ]
            }
          },
          metadata: %{"email_to" => "jane@example.com"}
        })

      assert {:ok, _} = Email.deliver_activity(ctx.channel, activity)
      assert_received {:email, email}

      assert email.text_body ==
               "How can I help?\n1. Track an order\n2. Talk to a human\nPricing: https://example.com/pricing"

      assert email.html_body =~ "<ol start=\"1\">"
      assert email.html_body =~ "<li>Talk to a human</li>"
      assert email.html_body =~ ~s(<a href="https://example.com/pricing">Pricing</a>)
    end

    test "renders the subject template", ctx do
      channel = %{
        ctx.channel
        | config: Map.put(@config, "subject_template", "Ticket {{conversation_id}}")
      }

      activity =
        activity_fixture(ctx.tenant, ctx.conversation, %{metadata: %{"to" => "a@x.test"}})

      assert {:ok, _} = Email.deliver_activity(channel, activity)
      assert_received {:email, email}
      assert email.subject == "Ticket #{ctx.conversation.id}"
    end

    test "replies to the latest inbound email of the conversation", ctx do
      activity_fixture(ctx.tenant, ctx.conversation, %{
        sender: "jane@example.com",
        metadata: %{
          "email" => %{
            "message_id" => "abc@mail.example.com",
            "references" => ["root@mail.example.com"],
            "subject" => "Printer broken",
            "from" => "jane@example.com"
          }
        }
      })

      reply = activity_fixture(ctx.tenant, ctx.conversation, %{text: "On it", sender: "agent"})

      assert {:ok, _} = Email.deliver_activity(ctx.channel, reply)
      assert_received {:email, email}
      assert email.to == [{"", "jane@example.com"}]
      assert email.subject == "Re: Printer broken"
      assert email.headers["In-Reply-To"] == "<abc@mail.example.com>"
      assert email.headers["References"] == "<root@mail.example.com> <abc@mail.example.com>"
    end

    test "attaches stored uploads and links the others", ctx do
      {:ok, upload} = Uploads.create_attachment(ctx.tenant.id, {"doc.pdf", "%PDF-1.4\n%%EOF\n"})

      activity =
        activity_fixture(ctx.tenant, ctx.conversation, %{
          text: "Files",
          metadata: %{"to" => "a@x.test"},
          attachments: [
            %{
              "contentType" => "application/pdf",
              "contentUrl" => "/api/v1/converger/attachments/#{upload.id}",
              "name" => "doc.pdf"
            },
            %{
              "contentType" => "image/png",
              "contentUrl" => "https://cdn.example.com/a.png",
              "name" => "a.png"
            }
          ]
        })

      assert {:ok, _} = Email.deliver_activity(ctx.channel, activity)
      assert_received {:email, email}

      assert [%Swoosh.Attachment{filename: "doc.pdf", data: "%PDF-1.4\n%%EOF\n"}] =
               email.attachments

      assert email.text_body =~ "a.png: https://cdn.example.com/a.png"
      assert email.html_body =~ ~s(href="https://cdn.example.com/a.png")
    end

    test "fails permanently without a recipient", ctx do
      activity = activity_fixture(ctx.tenant, ctx.conversation)

      assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
               Email.deliver_activity(ctx.channel, activity)

      assert reason =~ "no recipient"
    end
  end

  describe "parse_inbound/2" do
    test "strips the quote and keeps the full text in channelData", ctx do
      raw =
        "From: Jane <jane@example.com>\r\nTo: support@acme.test\r\nSubject: Re: Hi\r\n" <>
          "Message-ID: <m1@example.com>\r\nIn-Reply-To: <converger.00000000-0000-0000-0000-000000000001@acme.test>\r\n" <>
          "Content-Type: text/plain\r\n\r\nYes!\r\n\r\nOn Mon, Oct 6, 2026, Support wrote:\r\n> Hi\r\n"

      assert {:ok, [message]} =
               Email.parse_inbound(
                 ctx.channel |> Map.put(:config, Map.put(@config, "inbound_provider", "rfc822")),
                 %{"_body" => raw}
               )

      assert message["text"] == "Yes!"
      assert message["sender"] == "jane@example.com"
      assert message["idempotency_key"] == "m1@example.com"

      assert message["participant"] == %{
               "external_id" => "jane@example.com",
               "display_name" => "Jane"
             }

      assert message["thread_activity_ids"] == ["00000000-0000-0000-0000-000000000001"]
      assert "converger.00000000-0000-0000-0000-000000000001" in message["thread_refs"]
      assert message["metadata"]["email"]["subject"] == "Re: Hi"
      assert message["metadata"]["channelData"]["fullText"] =~ "Support wrote"
    end

    test "skips mail sent by the channel's own address", ctx do
      raw = "From: support@acme.test\r\nContent-Type: text/plain\r\n\r\nloop\r\n"
      channel = Map.put(ctx.channel, :config, Map.put(@config, "inbound_provider", "rfc822"))
      assert {:ok, []} = Email.parse_inbound(channel, %{"_body" => raw})
    end

    test "converts HTML-only mail to text" do
      assert Email.html_to_text("<style>p{}</style><p>Hi &amp; bye</p><br>x") == "Hi & bye\n\nx"
    end
  end
end
