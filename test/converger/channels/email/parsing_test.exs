defmodule Converger.Channels.Email.ParsingTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.Email.{Address, Mime, ReplyParser}

  describe "Address" do
    test "parses display names and normalizes addresses" do
      assert Address.parse(~s("Jane Doe" <Jane@Example.COM>)) == {"Jane Doe", "jane@example.com"}
      assert Address.parse("jane@example.com") == {nil, "jane@example.com"}
      assert Address.parse({"Jane", " Jane@Example.com "}) == {"Jane", "jane@example.com"}
      assert Address.parse("not an address") == nil
      assert Address.addresses("a@x.test, B <b@x.test>") == ["a@x.test", "b@x.test"]
    end

    test "message ids lose their brackets" do
      assert Address.normalize_id(" <abc@x> ") == "abc@x"
      assert Address.ids("<a@x>\r\n <b@y>") == ["a@x", "b@y"]
      assert Address.ids("bare@x") == ["bare@x"]
      assert Address.ids(nil) == []
    end
  end

  describe "ReplyParser" do
    test "cuts the quoted history at the attribution line" do
      body =
        "Thanks, that works!\r\n\r\nOn Mon, Oct 6, 2026 at 10:00 AM Support <s@x.test> wrote:\r\n> earlier"

      assert ReplyParser.strip(body) == "Thanks, that works!"
    end

    test "handles attribution lines wrapped over two lines" do
      body = "Yes please\n\nOn Mon, Oct 6, 2026 at 10:00 AM Support <\ns@x.test> wrote:\n> q"
      assert ReplyParser.strip(body) == "Yes please"
    end

    test "cuts Outlook headers, separators and signatures" do
      assert ReplyParser.strip("Ok\n\nFrom: Support\nSent: Monday\nTo: me") == "Ok"
      assert ReplyParser.strip("Ok\n-----Original Message-----\nold") == "Ok"
      assert ReplyParser.strip("Ok\n-- \nJane\nACME") == "Ok"
      assert ReplyParser.strip("Ok\n\nSent from my iPhone") == "Ok"

      assert ReplyParser.strip("Tamam\n\n6 Eki 2026 Pzt, Destek tarihinde şunu yazdı:\n> x") ==
               "Tamam"
    end

    test "keeps the whole body when nothing would be left" do
      assert ReplyParser.strip("> only a quote") == "> only a quote"
      assert ReplyParser.strip(nil) == ""
    end
  end

  describe "Mime.parse/1" do
    test "extracts headers, text, html and attachments" do
      raw =
        Enum.join(
          [
            ~s(From: "Jane Doe" <Jane@Example.com>),
            "To: support@acme.test",
            "Cc: Boss <boss@example.com>",
            "Subject: =?UTF-8?B?UmU6IEhlbGxvIMO8?=",
            "Message-ID: <abc@mail.example.com>",
            "In-Reply-To: <converger.1@acme.test>",
            "References: <a@x> <converger.1@acme.test>",
            "MIME-Version: 1.0",
            ~s(Content-Type: multipart/mixed; boundary="b1"),
            "",
            "--b1",
            ~s(Content-Type: multipart/alternative; boundary="b2"),
            "",
            "--b2",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Thanks!",
            "--b2",
            "Content-Type: text/html",
            "",
            "<p>Thanks!</p>",
            "--b2--",
            "--b1",
            ~s(Content-Type: application/pdf; name="a.pdf"),
            ~s(Content-Disposition: attachment; filename="a.pdf"),
            "Content-Transfer-Encoding: base64",
            "",
            "JVBERi0xLjQK",
            "--b1--",
            ""
          ],
          "\r\n"
        )

      assert {:ok, email} = Mime.parse(raw)
      assert email.from == "jane@example.com"
      assert email.from_name == "Jane Doe"
      assert email.to == ["support@acme.test"]
      assert email.cc == ["boss@example.com"]
      assert email.subject == "Re: Hello ü"
      assert email.message_id == "abc@mail.example.com"
      assert email.in_reply_to == ["converger.1@acme.test"]
      assert email.references == ["a@x", "converger.1@acme.test"]
      assert email.text == "Thanks!"
      assert email.html == "<p>Thanks!</p>"
      assert email.attachments == [{"a.pdf", "%PDF-1.4\n"}]
      assert email.report == nil
      refute email.auto_submitted
    end

    test "a message without Content-Type is plain text" do
      assert {:ok, %{text: "hello", auto_submitted: true}} =
               Mime.parse("From: a@b.test\r\nAuto-Submitted: auto-replied\r\n\r\nhello\r\n")
    end

    test "recognises a delivery status notification" do
      raw =
        Enum.join(
          [
            "From: MAILER-DAEMON@mx.example.com",
            "To: support@acme.test",
            "Subject: Undelivered Mail Returned to Sender",
            ~s(Content-Type: multipart/report; report-type=delivery-status; boundary="r"),
            "",
            "--r",
            "Content-Type: text/plain",
            "",
            "Delivery failed.",
            "--r",
            "Content-Type: message/delivery-status",
            "",
            "Reporting-MTA: dns; mx.example.com",
            "",
            "Final-Recipient: rfc822; nobody@example.com",
            "Action: failed",
            "Status: 5.1.1",
            "Diagnostic-Code: smtp; 550 5.1.1 user unknown",
            "--r",
            "Content-Type: text/rfc822-headers",
            "",
            "Message-ID: <converger.42@acme.test>",
            "Subject: Hello",
            "--r--",
            ""
          ],
          "\r\n"
        )

      assert {:ok, %{report: report}} = Mime.parse(raw)
      assert report.original_message_id == "converger.42@acme.test"
      assert report.reason =~ "5.1.1"
      assert report.reason =~ "user unknown"
    end

    test "rejects empty input" do
      assert Mime.parse("") == {:error, :invalid_mime}
    end
  end
end
