defmodule ConvergerWeb.MessageComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Converger.Activities.Activity
  alias ConvergerWeb.MessageComponents

  defp render_message(type, payload, opts \\ []) do
    activity = %Activity{
      id: Ecto.UUID.generate(),
      type: "message",
      text: Keyword.get(opts, :text),
      message_type: type,
      payload: payload
    }

    render_component(&MessageComponents.message_body/1,
      activity: activity,
      resolved_interrupts: Keyword.get(opts, :resolved, MapSet.new())
    )
  end

  describe "plain messages" do
    test "render their text, escaped" do
      html =
        render_component(&MessageComponents.message_body/1,
          activity: %Activity{text: "<b>hi</b> there"}
        )

      assert html =~ "&lt;b&gt;hi&lt;/b&gt; there"
      refute html =~ "data-message-type"
    end
  end

  describe "message types" do
    test "text with actions shows chips" do
      html =
        render_message("text", %{
          "data" => %{"text" => "Track it?"},
          "actions" => [%{"label" => "Track", "value" => "/track"}, %{"label" => "No thanks"}]
        })

      assert html =~ ~s(data-message-type="text")
      assert html =~ "Track it?"
      assert html =~ "Track"
      assert html =~ "No thanks"
    end

    test "quick-reply and buttons show their labels; url buttons link out safely" do
      html =
        render_message("quick-reply", %{
          "data" => %{
            "text" => "Helpful?",
            "actions" => [%{"label" => "Yes"}, %{"label" => "No"}]
          }
        })

      assert html =~ "Helpful?"
      assert html =~ "Yes"

      html =
        render_message("buttons", %{
          "data" => %{
            "text" => "How can I help?",
            "buttons" => [
              %{"label" => "Pricing", "url" => "https://example.com/pricing"},
              %{"label" => "Evil", "url" => "javascript:alert(1)"}
            ]
          }
        })

      assert html =~ ~s(href="https://example.com/pricing")
      assert html =~ ~s(rel="noopener noreferrer nofollow")
      assert html =~ "Evil"
      refute html =~ "javascript:"
    end

    test "card and carousel" do
      card = %{
        "title" => "ORD-1",
        "subtitle" => "249.90 USD",
        "text" => "Shipped yesterday",
        "image" => "https://example.com/ord-1.png",
        "buttons" => [%{"label" => "Track", "value" => "/track ORD-1"}]
      }

      html = render_message("card", %{"data" => card})
      assert html =~ "ORD-1"
      assert html =~ "249.90 USD"
      assert html =~ "Shipped yesterday"
      assert html =~ ~s(href="https://example.com/ord-1.png")
      assert html =~ "Track"

      html =
        render_message("carousel", %{
          "data" => %{"cards" => [card, %{"title" => "Pro", "subtitle" => "29 USD"}]}
        })

      assert html =~ "overflow-x-auto"
      assert html =~ "ORD-1"
      assert html =~ "Pro"
    end

    test "media render as links with metadata, never inline" do
      html =
        render_message("image", %{
          "data" => %{
            "src" => "https://example.com/r.png",
            "alt" => "Receipt",
            "caption" => "Yours"
          }
        })

      assert html =~ ~s(href="https://example.com/r.png")
      assert html =~ "Receipt"
      assert html =~ "Yours"
      refute html =~ "<img"

      html =
        render_message("file", %{
          "data" => %{
            "url" => "/api/v1/converger/attachments/9b7c4c1e-5a5f-4a0e-9a53-0e8d2f3f1a10",
            "name" => "invoice.pdf",
            "size" => 48_213,
            "mimeType" => "application/pdf"
          }
        })

      assert html =~ ~s(href="/api/v1/converger/attachments/9b7c4c1e-5a5f-4a0e-9a53-0e8d2f3f1a10")
      assert html =~ "invoice.pdf"
      assert html =~ "47.1 KB"
      assert html =~ "application/pdf"

      html =
        render_message("video", %{
          "data" => %{
            "src" => "https://example.com/howto.mp4",
            "poster" => "https://example.com/howto.jpg",
            "caption" => "Reset your router"
          }
        })

      assert html =~ ~s(href="https://example.com/howto.mp4")
      assert html =~ ~s(href="https://example.com/howto.jpg")
      assert html =~ "Reset your router"

      html =
        render_message("audio", %{
          "data" => %{"src" => "https://example.com/v.ogg", "voice" => true, "durationMs" => 4200}
        })

      assert html =~ "Voice message"
      assert html =~ "0:04"
    end

    test "location links to OpenStreetMap" do
      html =
        render_message("location", %{
          "data" => %{"latitude" => 41.0082, "longitude" => 28.9784, "name" => "Head office"}
        })

      assert html =~ "Head office"
      assert html =~ "https://www.openstreetmap.org/?mlat=41.0082&amp;mlon=28.9784"
    end

    test "contact shows name, phones and emails" do
      html =
        render_message("contact", %{
          "data" => %{
            "name" => "Support desk",
            "organization" => "ACME",
            "phones" => [%{"number" => "+90 212 000 00 00", "label" => "work"}],
            "emails" => [%{"address" => "help@example.com"}]
          }
        })

      assert html =~ "Support desk"
      assert html =~ "ACME"
      assert html =~ "+90 212 000 00 00"
      assert html =~ "work"
      assert html =~ "help@example.com"
    end

    test "tool_call is a collapsible trace with status and JSON" do
      html =
        render_message("tool_call", %{
          "data" => %{
            "id" => "t1",
            "name" => "get_order",
            "status" => "completed",
            "params" => %{"id" => "ORD-42"},
            "result" => %{"total" => 249.9}
          }
        })

      assert html =~ "<details"
      assert html =~ "get_order"
      assert html =~ "badge-success"
      assert html =~ "ORD-42"
      assert html =~ "249.9"
    end

    test "genui shows the chunk: component and props, text, event" do
      html =
        render_message("genui", %{
          "streamId" => "stream-1",
          "done" => false,
          "chunk" => %{
            "type" => "ui",
            "component" => "order-card",
            "props" => %{"id" => "ORD-42"}
          }
        })

      assert html =~ "stream-1"
      assert html =~ "order-card"
      assert html =~ "ORD-42"

      html =
        render_message("genui", %{
          "streamId" => "s",
          "done" => true,
          "chunk" => %{"type" => "text", "content" => "Processing"}
        })

      assert html =~ "Processing"
      assert html =~ "done"
    end

    test "interrupt is open until resolved; interrupt_resolved is a note" do
      payload = %{
        "id" => "approve/0:interrupt#0",
        "data" => %{
          "payload" => %{"title" => "249.90 TRY refund"},
          "actions" => [
            %{"label" => "Approve", "value" => %{"approved" => true}},
            %{"label" => "Reject", "value" => %{"approved" => false}}
          ]
        }
      }

      html = render_message("interrupt", payload)
      assert html =~ "249.90 TRY refund"
      assert html =~ "Approve"
      assert html =~ ~s(data-interrupt-state="open")

      html = render_message("interrupt", payload, resolved: MapSet.new(["approve/0:interrupt#0"]))
      assert html =~ ~s(data-interrupt-state="resolved")

      html =
        render_message("interrupt_resolved", %{
          "id" => "approve/0:interrupt#0",
          "data" => %{"answer" => %{"approved" => true}}
        })

      assert html =~ "approve/0:interrupt#0"
      assert html =~ "resolved"
      assert html =~ "approved"
    end

    test "skill is a badge" do
      html =
        render_message("skill", %{
          "data" => %{"id" => "s1", "name" => "pdf", "status" => "loaded", "source" => "server"}
        })

      assert html =~ "skill: pdf"
      assert html =~ "loaded"
    end

    test "unknown types show data.text, else the payload as JSON" do
      html = render_message("order-status", %{"data" => %{"text" => "Order shipped"}})
      assert html =~ "order-status"
      assert html =~ "Order shipped"

      html = render_message("order-status", %{"data" => %{"step" => 3}})
      assert html =~ "&quot;step&quot;: 3"
    end

    test "non-string values never crash the rendering" do
      html =
        render_message("card", %{
          "data" => %{"title" => %{"nested" => true}, "buttons" => ["x", %{"label" => [1]}]}
        })

      assert html =~ ~s(data-message-type="card")
    end
  end

  describe "security" do
    test "payload markup is escaped everywhere" do
      xss = ~s|<script>alert("x")</script><img src=x onerror=alert(1)>|

      for {type, payload} <- [
            {"text", %{"data" => %{"text" => xss}, "actions" => [%{"label" => xss}]}},
            {"card", %{"data" => %{"title" => xss, "subtitle" => xss, "text" => xss}}},
            {"tool_call",
             %{
               "data" => %{
                 "id" => "t",
                 "name" => xss,
                 "status" => "error",
                 "params" => %{"q" => xss}
               }
             }},
            {"genui",
             %{
               "streamId" => xss,
               "done" => true,
               "chunk" => %{"type" => "text", "content" => xss}
             }},
            {"contact", %{"data" => %{"name" => xss, "phones" => [%{"number" => xss}]}}},
            {"x-custom", %{"data" => %{"text" => xss}}}
          ] do
        html = render_message(type, payload)
        refute html =~ "<script>", "#{type} rendered a raw script tag"
        refute html =~ "<img src=x", "#{type} rendered a raw img tag"
        assert html =~ "&lt;script&gt;"
      end
    end

    test "javascript: and other unsafe URLs are refused" do
      for url <- [
            "javascript:alert(1)",
            "JavaScript:alert(1)",
            " javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "//evil.example/x.png",
            "vbscript:msgbox(1)",
            "relative/path.png"
          ] do
        assert MessageComponents.safe_url(url) == nil, "#{url} accepted"

        html = render_message("image", %{"data" => %{"src" => url, "alt" => "pic"}})
        refute html =~ "href=", "#{url} rendered as a link"
        assert html =~ "data-refused-url"
      end

      assert MessageComponents.safe_url("https://example.com/a.png") ==
               "https://example.com/a.png"

      assert MessageComponents.safe_url("/api/v1/converger/attachments/1") =~ "/api/"
    end

    test "huge JSON is truncated" do
      big = %{"blob" => String.duplicate("a", 50_000)}

      html =
        render_message("tool_call", %{
          "data" => %{"id" => "t", "name" => "dump", "status" => "completed", "result" => big}
        })

      assert html =~ "(truncated)"
      assert byte_size(html) < 10_000
    end
  end

  describe "interrupt tracking" do
    test "records resolutions and finds the row to re-render" do
      interrupt = %Activity{id: "a1", message_type: "interrupt", payload: %{"id" => "i1"}}
      resolved = %Activity{id: "a2", message_type: "interrupt_resolved", payload: %{"id" => "i1"}}
      plain = %Activity{id: "a3", text: "hi"}

      state =
        MessageComponents.track_interrupts(MessageComponents.interrupt_state(), [interrupt, plain])

      refute MapSet.member?(state.resolved, "i1")

      state = MessageComponents.track_interrupts(state, [resolved])
      assert MapSet.member?(state.resolved, "i1")
      assert MessageComponents.resolved_interrupt_row(state, resolved) == interrupt
      assert MessageComponents.resolved_interrupt_row(state, plain) == nil
    end
  end
end
