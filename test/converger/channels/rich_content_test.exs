defmodule Converger.Channels.RichContentTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.RichContent

  @id "6f1c2a4e-0b7d-4c55-9a1e-3d2f8e7b9c10"

  defp typed(message_type, payload, text \\ nil) do
    %{id: @id, type: "message", text: text, message_type: message_type, payload: payload}
  end

  defp buttons_payload do
    %{
      "data" => %{
        "text" => "How can I help?",
        "buttons" => [
          %{"label" => "Track an order", "value" => "/track"},
          %{"label" => "Pricing", "url" => "https://example.com/pricing"},
          %{"label" => "Talk to a human"}
        ]
      }
    }
  end

  defp carousel_payload do
    %{
      "data" => %{
        "text" => "Pick a plan",
        "cards" => [
          %{
            "title" => "Basic",
            "subtitle" => "9 USD / month",
            "image" => "https://example.com/basic.png",
            "buttons" => [%{"label" => "Pick", "value" => "basic"}]
          },
          %{"title" => "Pro", "buttons" => [%{"label" => "Pick", "value" => "pro"}]}
        ]
      }
    }
  end

  describe "actions/2" do
    test "flattens and numbers the answerable actions; links have no number" do
      assert [
               %{"index" => 0, "number" => 1, "label" => "Track an order", "value" => "/track"},
               %{"index" => 1, "number" => nil, "url" => "https://example.com/pricing"},
               %{"index" => 2, "number" => 2, "label" => "Talk to a human", "value" => nil}
             ] = RichContent.actions("buttons", buttons_payload())
    end

    test "reads every actionable type" do
      chips = [%{"label" => "Yes", "value" => "yes"}]

      assert [%{"label" => "Yes"}] =
               RichContent.actions("text", %{"data" => %{"text" => "?"}, "actions" => chips})

      assert [%{"label" => "Yes"}] =
               RichContent.actions("quick-reply", %{
                 "data" => %{"text" => "?", "actions" => chips}
               })

      assert [%{"label" => "Yes"}] =
               RichContent.actions("interrupt", %{"data" => %{"actions" => chips}})

      assert [%{"card" => 0, "number" => 1}, %{"card" => 1, "number" => 2, "value" => "pro"}] =
               RichContent.actions("carousel", carousel_payload())

      assert [] == RichContent.actions("image", %{"data" => %{"src" => "x"}})
    end
  end

  describe "text/1 and html/1" do
    test "a numbered list with links after it" do
      assert RichContent.text(typed("buttons", buttons_payload())) ==
               "How can I help?\n1. Track an order\n2. Talk to a human\nPricing: https://example.com/pricing"
    end

    test "carousel cards are blocks, numbering continues, images as links" do
      assert RichContent.text(typed("carousel", carousel_payload())) ==
               "Pick a plan\n\nBasic\n9 USD / month\nhttps://example.com/basic.png\n1. Pick\n\nPro\n2. Pick"
    end

    test "interrupts use payload.title as the prompt" do
      payload = %{
        "data" => %{
          "payload" => %{"title" => "Refund 249.90 TRY?"},
          "actions" => [%{"label" => "Approve", "value" => %{"approved" => true}}]
        }
      }

      assert RichContent.text(typed("interrupt", payload)) == "Refund 249.90 TRY?\n1. Approve"
    end

    test "media, location and contact render as text with links" do
      assert RichContent.text(
               typed("image", %{
                 "data" => %{"src" => "https://x.test/a.png", "caption" => "Receipt"}
               })
             ) == "Receipt\nhttps://x.test/a.png"

      assert RichContent.text(
               typed("location", %{
                 "data" => %{"latitude" => 41.0, "longitude" => 28.9, "name" => "HQ"}
               })
             ) == "HQ\nhttps://maps.google.com/?q=41.0,28.9"

      assert RichContent.text(
               typed("contact", %{
                 "data" => %{"name" => "Support", "phones" => [%{"number" => "+90 212"}]}
               })
             ) == "Support: +90 212"
    end

    test "falls back to the stored text for other types and plain messages" do
      assert RichContent.text(typed("order-card", %{"data" => %{}}, "fallback")) == "fallback"
      assert RichContent.text(%{text: "plain"}) == "plain"
    end

    test "HTML has an ordered list, escaped labels and links" do
      payload = put_in(buttons_payload(), ["data", "text"], "<b>Help</b>")
      html = RichContent.html(typed("buttons", payload))

      assert html =~ "<p>&lt;b&gt;Help&lt;/b&gt;</p>"
      assert html =~ ~s(<ol start="1">\n<li>Track an order</li>\n<li>Talk to a human</li>\n</ol>)
      assert html =~ ~s(<a href="https://example.com/pricing">Pricing</a>)
      assert RichContent.html(%{text: "plain"}) == nil
    end
  end

  describe "attachment/2" do
    test "media become file attachments with a content type" do
      assert {"Receipt", %{"contentType" => "image/png", "contentUrl" => "https://x.test/a.png"}} =
               RichContent.attachment("image", %{
                 "data" => %{"src" => "https://x.test/a.png", "caption" => "Receipt"}
               })

      assert {nil, %{"contentType" => "audio/ogg", "channelData" => %{"voice" => true}}} =
               RichContent.attachment("audio", %{
                 "data" => %{
                   "src" => "https://x.test/v",
                   "mimeType" => "audio/ogg",
                   "voice" => true
                 }
               })

      assert {nil, %{"contentType" => "video/mp4"}} =
               RichContent.attachment("video", %{"data" => %{"src" => "https://x.test/v"}})

      assert nil == RichContent.attachment("image", %{"data" => %{"src" => "ftp://x"}})
    end

    test "location and contact become the well-known attachments" do
      assert {nil,
              %{
                "contentType" => "application/vnd.converger.location",
                "content" => %{"latitude" => 1.5, "longitude" => 2.5, "name" => "HQ"}
              }} =
               RichContent.attachment("location", %{
                 "data" => %{"latitude" => 1.5, "longitude" => 2.5, "name" => "HQ", "text" => "t"}
               })

      assert {nil,
              %{
                "contentType" => "application/vnd.converger.contacts",
                "content" => [%{"name" => "Desk", "phones" => ["+1"], "emails" => ["d@x.test"]}]
              }} =
               RichContent.attachment("contact", %{
                 "data" => %{
                   "name" => "Desk",
                   "phones" => [%{"number" => "+1"}],
                   "emails" => [%{"address" => "d@x.test"}]
                 }
               })
    end
  end

  describe "answers" do
    test "answer keys fit Telegram's 64 bytes and parse back" do
      ref = RichContent.ref(@id, 12)
      assert byte_size(ref) <= 64
      assert {:ok, @id, 12} == RichContent.parse_ref(ref)
      assert :error == RichContent.parse_ref("a:not-a-uuid:1")
      assert :error == RichContent.parse_ref(nil)
    end

    test "the answer text is a string value, else the label" do
      assert {"/track", %{"label" => "Track", "value" => "/track", "source" => "button"}} =
               RichContent.answer(%{"label" => "Track", "value" => "/track"}, "button")

      assert {"Yes", %{"value" => "Yes"}} = RichContent.answer(%{"label" => "Yes"}, "list")

      assert {"Approve", %{"value" => %{"approved" => true}}} =
               RichContent.answer(
                 %{"label" => "Approve", "value" => %{"approved" => true}},
                 "numeric"
               )
    end

    test "numeric replies" do
      assert {:ok, 2} == RichContent.numeric("2")
      assert {:ok, 2} == RichContent.numeric(" 2. ")
      assert {:ok, 10} == RichContent.numeric("10)")
      assert :error == RichContent.numeric("2 please")
      assert :error == RichContent.numeric(nil)
    end

    test "put_answer only marks answer keys" do
      ref = RichContent.ref(@id, 0)

      assert %{"answer" => %{"ref" => ^ref, "source" => "list", "label" => "Yes"}} =
               RichContent.put_answer(%{}, ref, "list", "Yes")

      assert %{} == RichContent.put_answer(%{}, "legacy-button-id", "button")
    end
  end

  test "truncate keeps short labels and marks cut ones" do
    assert RichContent.truncate("Track", 20) == "Track"
    assert RichContent.truncate("Talk to a human agent please", 20) == "Talk to a human age…"
    assert String.length(RichContent.truncate(String.duplicate("x", 30), 24)) == 24
  end

  test "interrupts answered by the client runtime are skipped" do
    assert RichContent.skip?(typed("interrupt", %{"data" => %{"tool" => %{"name" => "x"}}}))
    assert RichContent.skip?(typed("interrupt", %{"data" => %{"event" => "x"}}))
    refute RichContent.skip?(typed("interrupt", %{"data" => %{"actions" => []}}))
  end
end
