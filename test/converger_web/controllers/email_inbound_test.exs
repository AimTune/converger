defmodule ConvergerWeb.EmailInboundTest do
  use ConvergerWeb.ConnCase

  import Ecto.Query

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures
  import Converger.DeliveriesFixtures

  alias Converger.{Activities, Conversations, Deliveries, Repo}
  alias Converger.Activities.Activity
  alias Converger.Channels.Adapters.Email
  alias Converger.Channels.Email.SNS

  @base %{"from" => "ACME Support <support@acme.test>", "inbound_secret" => "s3cret"}
  @topic "arn:aws:sns:eu-west-1:123456789012:converger-inbound"
  @cert_url "https://sns.eu-west-1.amazonaws.com/SimpleNotificationService-test.pem"

  setup do
    tenant = tenant_fixture()
    web = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, web)
    %{tenant: tenant, conversation: conversation}
  end

  defp email_channel(tenant, config) do
    channel_fixture(tenant, %{type: "email", config: Map.merge(@base, config)})
  end

  # Sends `text` from the conversation to `jane@example.com` through `channel`
  # and records the delivery as the pipeline would.
  defp send_outbound(tenant, conversation, channel, text \\ "How can we help?") do
    activity =
      activity_fixture(tenant, conversation, %{
        text: text,
        sender: "agent",
        metadata: %{"email_to" => "jane@example.com"}
      })

    {:ok, meta} = Email.deliver_activity(channel, activity)
    assert_received {:email, _}
    {:ok, delivery} = Deliveries.mark_sent(delivery_fixture(activity, channel), meta)
    {activity, delivery}
  end

  defp basic_auth(conn, password \\ "s3cret"),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("converger:" <> password))

  defp post_raw(conn, channel, raw, content_type \\ "message/rfc822") do
    conn
    |> put_req_header("content-type", content_type)
    |> post(~p"/api/v1/channels/#{channel.id}/inbound", raw)
  end

  defp reply_mime(opts) do
    headers =
      [
        "From: Jane Doe <Jane@Example.com>",
        "To: support@acme.test",
        "Subject: Re: New message",
        "Message-ID: <#{Keyword.get(opts, :id, "reply-1@example.com")}>"
      ] ++
        if(opts[:in_reply_to], do: ["In-Reply-To: <#{opts[:in_reply_to]}>"], else: [])

    Enum.join(
      headers ++
        [
          "Content-Type: text/plain; charset=utf-8",
          "",
          Keyword.get(opts, :text, "The printer is on fire."),
          "",
          "On Mon, Oct 6, 2026 at 10:00 AM ACME Support <support@acme.test> wrote:",
          "> How can we help?",
          ""
        ],
      "\r\n"
    )
  end

  defp activities(conversation_id) do
    Repo.all(from a in Activity, where: a.conversation_id == ^conversation_id, order_by: a.seq)
  end

  describe "replies (rfc822)" do
    setup %{tenant: tenant} do
      %{
        channel: email_channel(tenant, %{"provider" => "smtp", "smtp_host" => "smtp.example.com"})
      }
    end

    test "a reply to an outbound email lands in the originating conversation", ctx do
      {activity, _delivery} = send_outbound(ctx.tenant, ctx.conversation, ctx.channel)
      raw = reply_mime(in_reply_to: "converger.#{activity.id}@acme.test")

      conn = ctx.conn |> basic_auth() |> post_raw(ctx.channel, raw)

      assert %{"status" => "accepted", "activity_ids" => [id]} = json_response(conn, 200)
      reply = Activities.get_activity!(id)
      assert reply.conversation_id == ctx.conversation.id
      assert reply.text == "The printer is on fire."
      assert reply.sender == "jane@example.com"
      assert reply.reply_to_id == activity.id
      assert reply.metadata["email"]["message_id"] == "reply-1@example.com"

      # The next outbound email continues the thread.
      send_outbound(ctx.tenant, ctx.conversation, ctx.channel, "Calling the fire brigade")
    end

    test "a reply matched through a provider-rewritten Message-ID", ctx do
      activity = activity_fixture(ctx.tenant, ctx.conversation, %{sender: "agent"})

      {:ok, _} =
        Deliveries.mark_sent(delivery_fixture(activity, ctx.channel), %{
          provider_message_id: "0102018f-ses-id"
        })

      raw = reply_mime(in_reply_to: "0102018f-ses-id@eu-west-1.amazonses.com")
      conn = ctx.conn |> basic_auth() |> post_raw(ctx.channel, raw)

      assert %{"activity_ids" => [id]} = json_response(conn, 200)
      assert Activities.get_activity!(id).conversation_id == ctx.conversation.id
    end

    test "a re-delivered email is a duplicate", ctx do
      raw = reply_mime(id: "dup@example.com")
      assert json_response(ctx.conn |> basic_auth() |> post_raw(ctx.channel, raw), 200)

      conn = build_conn() |> basic_auth() |> post_raw(ctx.channel, raw)
      assert %{"duplicates" => 1} = json_response(conn, 200)
    end

    test "a new email without references starts a participant conversation", ctx do
      conn = ctx.conn |> basic_auth() |> post_raw(ctx.channel, reply_mime(text: "Hello"))
      assert %{"activity_ids" => [id]} = json_response(conn, 200)

      conversation = Conversations.get_conversation!(Activities.get_activity!(id).conversation_id)
      assert conversation.channel_id == ctx.channel.id
      assert conversation.id != ctx.conversation.id
    end

    test "a reply to a closed conversation starts a new one", ctx do
      {activity, _} = send_outbound(ctx.tenant, ctx.conversation, ctx.channel)
      {:ok, _} = Conversations.close_conversation(ctx.conversation)

      raw = reply_mime(in_reply_to: "converger.#{activity.id}@acme.test")
      conn = ctx.conn |> basic_auth() |> post_raw(ctx.channel, raw)

      assert %{"activity_ids" => [id]} = json_response(conn, 200)
      assert Activities.get_activity!(id).conversation_id != ctx.conversation.id
    end

    test "references to activities never sent through the channel are ignored", ctx do
      foreign = activity_fixture(ctx.tenant, ctx.conversation)
      raw = reply_mime(in_reply_to: "converger.#{foreign.id}@acme.test")
      conn = ctx.conn |> basic_auth() |> post_raw(ctx.channel, raw)

      assert %{"activity_ids" => [id]} = json_response(conn, 200)
      assert Activities.get_activity!(id).conversation_id != ctx.conversation.id
    end

    test "rejects a wrong basic auth password", ctx do
      conn = ctx.conn |> basic_auth("nope") |> post_raw(ctx.channel, reply_mime([]))
      assert conn.status == 401
    end

    test "a delivery status notification fails the delivery", ctx do
      {activity, delivery} = send_outbound(ctx.tenant, ctx.conversation, ctx.channel)

      dsn =
        Enum.join(
          [
            "From: MAILER-DAEMON@mx.example.com",
            "To: support@acme.test",
            ~s(Content-Type: multipart/report; report-type=delivery-status; boundary="r"),
            "",
            "--r",
            "Content-Type: message/delivery-status",
            "",
            "Action: failed",
            "Status: 5.1.1",
            "Diagnostic-Code: smtp; 550 user unknown",
            "--r",
            "Content-Type: text/rfc822-headers",
            "",
            "Message-ID: <converger.#{activity.id}@acme.test>",
            "--r--",
            ""
          ],
          "\r\n"
        )

      conn = ctx.conn |> basic_auth() |> post_raw(ctx.channel, dsn)
      assert %{"receipts_processed" => 1} = json_response(conn, 200)

      failed = Deliveries.get_delivery!(delivery.id)
      assert failed.status == "failed"
      assert failed.last_error =~ "550 user unknown"
      assert activities(ctx.conversation.id) |> length() == 1
    end
  end

  describe "postmark" do
    setup %{tenant: tenant} do
      %{channel: email_channel(tenant, %{"provider" => "postmark", "api_key" => "pm"})}
    end

    test "inbound webhook with an attachment", ctx do
      {activity, _} = send_outbound(ctx.tenant, ctx.conversation, ctx.channel)

      payload = %{
        "FromFull" => %{"Email" => "Jane@Example.com", "Name" => "Jane"},
        "ToFull" => [%{"Email" => "support@acme.test"}],
        "Subject" => "Re: New message",
        "MessageID" => "pm-inbound-1",
        "TextBody" => "See attached\n\nOn Mon, Support wrote:\n> hi",
        "StrippedTextReply" => "See attached",
        "Headers" => [
          %{"Name" => "Message-ID", "Value" => "<pm-1@example.com>"},
          %{"Name" => "In-Reply-To", "Value" => "<converger.#{activity.id}@acme.test>"}
        ],
        "Attachments" => [
          %{
            "Name" => "doc.pdf",
            "Content" => Base.encode64("%PDF-1.4\n%%EOF\n"),
            "ContentType" => "application/pdf"
          }
        ]
      }

      conn =
        ctx.conn |> basic_auth() |> post(~p"/api/v1/channels/#{ctx.channel.id}/inbound", payload)

      assert %{"activity_ids" => [id]} = json_response(conn, 200)
      reply = Activities.get_activity!(id)
      assert reply.conversation_id == ctx.conversation.id
      assert reply.text == "See attached"

      assert [
               %{
                 "contentType" => "application/pdf",
                 "contentUrl" => "/api/v1/converger/attachments/" <> _
               }
             ] =
               reply.attachments
    end

    test "a bounce fails the delivery with its reason", ctx do
      {_activity, delivery} = send_outbound(ctx.tenant, ctx.conversation, ctx.channel)

      payload = %{
        "RecordType" => "Bounce",
        "Type" => "HardBounce",
        "MessageID" => delivery.provider_message_id,
        "Description" => "The server was unable to deliver your message",
        "BouncedAt" => "2026-10-10T10:00:00Z"
      }

      conn =
        ctx.conn |> basic_auth() |> post(~p"/api/v1/channels/#{ctx.channel.id}/inbound", payload)

      assert %{"receipts_processed" => 1} = json_response(conn, 200)

      failed = Deliveries.get_delivery!(delivery.id)
      assert failed.status == "failed"

      assert failed.last_error ==
               "bounce: HardBounce: The server was unable to deliver your message"
    end

    test "a spam complaint fails the delivery", ctx do
      {_activity, delivery} = send_outbound(ctx.tenant, ctx.conversation, ctx.channel)

      conn =
        ctx.conn
        |> basic_auth()
        |> post(~p"/api/v1/channels/#{ctx.channel.id}/status", %{
          "RecordType" => "SpamComplaint",
          "MessageID" => delivery.provider_message_id
        })

      assert %{"receipts_processed" => 1} = json_response(conn, 200)
      assert %{status: "failed", last_error: "complaint"} = Deliveries.get_delivery!(delivery.id)
    end
  end

  describe "ses (SNS)" do
    setup %{tenant: tenant} do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      %{cert: der} = :public_key.pkix_test_root_cert(~c"SNS test", key: key)
      pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
      {:ok, public_key} = SNS.extract_public_key(pem)
      :persistent_term.put({SNS, :cert, @cert_url}, public_key)

      channel =
        email_channel(tenant, %{
          "provider" => "ses",
          "aws_region" => "eu-west-1",
          "aws_access_key_id" => "AKIA",
          "aws_access_key_secret" => "secret",
          "ses_topic_arn" => @topic
        })

      %{channel: channel, key: key}
    end

    defp sns(key, type, fields) do
      message =
        Map.merge(
          %{
            "Type" => type,
            "MessageId" => Ecto.UUID.generate(),
            "TopicArn" => @topic,
            "Timestamp" => "2026-10-10T10:00:00.000Z",
            "SignatureVersion" => "2",
            "SigningCertURL" => @cert_url
          },
          fields
        )

      {:ok, canonical} = SNS.canonical(message)
      signature = canonical |> :public_key.sign(:sha256, key) |> Base.encode64()
      Jason.encode!(Map.put(message, "Signature", signature))
    end

    test "a bounce notification fails the delivery", ctx do
      activity = activity_fixture(ctx.tenant, ctx.conversation, %{sender: "agent"})

      {:ok, delivery} =
        Deliveries.mark_sent(delivery_fixture(activity, ctx.channel), %{
          provider_message_id: "ses-1"
        })

      notification = %{
        "notificationType" => "Bounce",
        "bounce" => %{
          "bounceType" => "Permanent",
          "bounceSubType" => "NoEmail",
          "bouncedRecipients" => [%{"diagnosticCode" => "smtp; 550 no such user"}],
          "timestamp" => "2026-10-10T10:00:00.000Z"
        },
        "mail" => %{"messageId" => "ses-1"}
      }

      body = sns(ctx.key, "Notification", %{"Message" => Jason.encode!(notification)})
      conn = post_raw(ctx.conn, ctx.channel, body, "text/plain; charset=UTF-8")

      assert %{"receipts_processed" => 1} = json_response(conn, 200)
      failed = Deliveries.get_delivery!(delivery.id)
      assert failed.status == "failed"
      assert failed.last_error == "bounce: Permanent: NoEmail: smtp; 550 no such user"
    end

    test "a received email becomes an activity", ctx do
      notification = %{
        "notificationType" => "Received",
        "receipt" => %{"action" => %{"type" => "SNS", "encoding" => "BASE64"}},
        "mail" => %{"messageId" => "inbound-ses-id"},
        "content" => Base.encode64(reply_mime(text: "Via SES"))
      }

      body = sns(ctx.key, "Notification", %{"Message" => Jason.encode!(notification)})
      conn = post_raw(ctx.conn, ctx.channel, body, "text/plain; charset=UTF-8")

      assert %{"activity_ids" => [id]} = json_response(conn, 200)
      assert Activities.get_activity!(id).text == "Via SES"
    end

    test "rejects a tampered message and a foreign topic", ctx do
      body = sns(ctx.key, "Notification", %{"Message" => "{}"})
      tampered = String.replace(body, "{}", ~s({"x":1}))
      assert post_raw(ctx.conn, ctx.channel, tampered, "text/plain").status == 401

      foreign =
        sns(ctx.key, "Notification", %{"Message" => "{}", "TopicArn" => @topic <> "-other"})

      assert post_raw(build_conn(), ctx.channel, foreign, "text/plain").status == 401
    end

    test "confirms the subscription", ctx do
      Application.put_env(:converger, :email_req_options, plug: {Req.Test, __MODULE__})
      on_exit(fn -> Application.delete_env(:converger, :email_req_options) end)

      Req.Test.stub(__MODULE__, fn conn ->
        send(self(), {:subscribed, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "<ConfirmSubscriptionResponse/>")
      end)

      body =
        sns(ctx.key, "SubscriptionConfirmation", %{
          "Message" => "You have chosen to subscribe",
          "Token" => "tok",
          "SubscribeURL" =>
            "https://sns.eu-west-1.amazonaws.com/?Action=ConfirmSubscription&Token=tok"
        })

      conn = post_raw(ctx.conn, ctx.channel, body, "text/plain")
      assert json_response(conn, 200)["status"] == "accepted"
      assert_received {:subscribed, "/"}
    end
  end

  describe "mailgun" do
    setup %{tenant: tenant} do
      channel =
        email_channel(tenant, %{
          "provider" => "mailgun",
          "api_key" => "key",
          "mailgun_domain" => "mg.acme.test",
          "mailgun_signing_secret" => "mg-signing"
        })

      %{channel: channel}
    end

    defp mailgun_signature(secret \\ "mg-signing") do
      timestamp = Integer.to_string(System.system_time(:second))
      token = "tok-#{System.unique_integer([:positive])}"

      signature =
        :crypto.mac(:hmac, :sha256, secret, timestamp <> token) |> Base.encode16(case: :lower)

      %{"timestamp" => timestamp, "token" => token, "signature" => signature}
    end

    test "a signed route post becomes an activity in the thread", ctx do
      {activity, _} = send_outbound(ctx.tenant, ctx.conversation, ctx.channel)

      params =
        Map.merge(mailgun_signature(), %{
          "from" => "Jane <jane@example.com>",
          "To" => "support@acme.test",
          "subject" => "Re: New message",
          "Message-Id" => "<mg-1@example.com>",
          "In-Reply-To" => "<converger.#{activity.id}@acme.test>",
          "body-plain" => "Thanks\n\nOn Mon, Support wrote:\n> x",
          "stripped-text" => "Thanks"
        })

      conn = post(ctx.conn, ~p"/api/v1/channels/#{ctx.channel.id}/inbound", params)
      assert %{"activity_ids" => [id]} = json_response(conn, 200)
      reply = Activities.get_activity!(id)
      assert reply.conversation_id == ctx.conversation.id
      assert reply.text == "Thanks"
    end

    test "rejects a bad signature", ctx do
      params =
        Map.merge(mailgun_signature("wrong"), %{"from" => "jane@example.com", "body-plain" => "x"})

      assert post(ctx.conn, ~p"/api/v1/channels/#{ctx.channel.id}/inbound", params).status == 401
    end

    test "a permanent failure event fails the delivery", ctx do
      activity = activity_fixture(ctx.tenant, ctx.conversation, %{sender: "agent"})

      {:ok, delivery} =
        Deliveries.mark_sent(delivery_fixture(activity, ctx.channel), %{
          provider_message_id: "20261010.1@mg.acme.test"
        })

      payload = %{
        "signature" => mailgun_signature(),
        "event-data" => %{
          "event" => "failed",
          "severity" => "permanent",
          "timestamp" => 1_791_000_000.123,
          "delivery-status" => %{"description" => "No such mailbox"},
          "message" => %{"headers" => %{"message-id" => "20261010.1@mg.acme.test"}}
        }
      }

      conn = post(ctx.conn, ~p"/api/v1/channels/#{ctx.channel.id}/status", payload)
      assert %{"receipts_processed" => 1} = json_response(conn, 200)

      assert %{status: "failed", last_error: "bounce: No such mailbox"} =
               Deliveries.get_delivery!(delivery.id)
    end
  end

  describe "sendgrid" do
    setup %{tenant: tenant} do
      %{channel: email_channel(tenant, %{"provider" => "sendgrid", "api_key" => "sg"})}
    end

    test "inbound parse fields with an uploaded attachment", ctx do
      path = Path.join(System.tmp_dir!(), "sg-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "plain text attachment")
      on_exit(fn -> File.rm(path) end)

      params = %{
        "from" => "Jane <jane@example.com>",
        "to" => "support@acme.test",
        "subject" => "Question",
        "headers" => "Message-ID: <sg-1@example.com>\nSubject: Question\n",
        "text" => "Is it open?",
        "attachments" => "1",
        "attachment1" => %Plug.Upload{
          path: path,
          filename: "notes.txt",
          content_type: "text/plain"
        }
      }

      conn =
        ctx.conn |> basic_auth() |> post(~p"/api/v1/channels/#{ctx.channel.id}/inbound", params)

      assert %{"activity_ids" => [id]} = json_response(conn, 200)

      activity = Activities.get_activity!(id)
      assert activity.text == "Is it open?"
      assert activity.idempotency_key == "sg-1@example.com"
      assert [%{"name" => "notes.txt", "contentType" => "text/plain"}] = activity.attachments
    end

    test "bounce events fail the delivery", ctx do
      activity = activity_fixture(ctx.tenant, ctx.conversation, %{sender: "agent"})

      {:ok, delivery} =
        Deliveries.mark_sent(delivery_fixture(activity, ctx.channel), %{
          provider_message_id: "sgid123"
        })

      events = [
        %{"event" => "processed", "sg_message_id" => "sgid123.filter0001.1.0"},
        %{
          "event" => "bounce",
          "type" => "bounce",
          "reason" => "550 5.1.1 unknown",
          "sg_message_id" => "sgid123.filter0001.1.0",
          "timestamp" => 1_791_000_000
        }
      ]

      conn =
        ctx.conn
        |> basic_auth()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/channels/#{ctx.channel.id}/status", Jason.encode!(events))

      assert %{"receipts_processed" => 1} = json_response(conn, 200)

      assert %{status: "failed", last_error: "bounce: 550 5.1.1 unknown"} =
               Deliveries.get_delivery!(delivery.id)
    end
  end
end
