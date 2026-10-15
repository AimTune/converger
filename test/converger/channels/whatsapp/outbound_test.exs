defmodule Converger.Channels.WhatsApp.OutboundTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.DeliveryError
  alias Converger.Channels.WhatsApp.Outbound

  defp activity(attrs) do
    Map.merge(%{text: nil, attachments: [], metadata: %{}}, Map.new(attrs))
  end

  defp image(url \\ "https://cdn.example.com/a.jpg"),
    do: %{"contentType" => "image/jpeg", "contentUrl" => url}

  describe "typed messages (#68)" do
    @id "6f1c2a4e-0b7d-4c55-9a1e-3d2f8e7b9c10"

    defp typed(type, payload, text \\ nil),
      do: activity(id: @id, text: text, message_type: type, payload: payload)

    defp labels(n), do: for(i <- 1..n, do: %{"label" => "Option #{i}", "value" => "v#{i}"})

    test "1 to 3 actions are reply buttons whose ids are answer keys" do
      payload = %{"data" => %{"text" => "Pick", "buttons" => labels(3)}}

      assert {:ok, [{:buttons, %{"body" => "Pick", "buttons" => buttons}}]} =
               Outbound.parts(typed("buttons", payload))

      assert Enum.map(buttons, & &1["id"]) == for(i <- 0..2, do: "a:#{@id}:#{i}")
    end

    test "4 to 10 actions are a list; long labels are cut and kept as description" do
      long = "A very long option label that WhatsApp cuts"
      actions = [%{"label" => long} | labels(4)]
      payload = %{"data" => %{"text" => "Choose"}, "actions" => actions}

      assert {:ok,
              [{:list, %{"body" => "Choose", "button" => "Options", "sections" => [section]}}]} =
               Outbound.parts(typed("text", payload))

      assert [%{"id" => "a:" <> _, "title" => title, "description" => description} | _] =
               section["rows"]

      assert String.length(title) == 24
      assert description == long
      assert length(section["rows"]) == 5
    end

    test "more than 10 actions are a numbered text" do
      payload = %{"data" => %{"text" => "Many", "actions" => labels(11)}}

      assert {:ok, [{:text, text}]} = Outbound.parts(typed("quick-reply", payload))
      assert text =~ "Many\n\n1. Option 1\n"
      assert text =~ "11. Option 11"
    end

    test "interrupts use their title as the body" do
      payload = %{
        "data" => %{
          "payload" => %{"title" => "Refund?"},
          "actions" => [%{"label" => "Approve", "value" => %{"approved" => true}}]
        }
      }

      assert {:ok, [{:buttons, %{"body" => "Refund?"}}]} =
               Outbound.parts(typed("interrupt", payload))
    end

    test "a carousel is its text, then one card after the other" do
      payload = %{
        "data" => %{
          "text" => "Plans",
          "cards" => [
            %{"title" => "Basic", "image" => "https://x.test/b.png", "buttons" => labels(1)},
            %{"title" => "Pro", "buttons" => [%{"label" => "Pick", "value" => "pro"}]},
            %{"title" => "Info", "image" => "https://x.test/i.png"}
          ]
        }
      }

      assert {:ok,
              [
                {:text, "Plans"},
                {:media, "image", %{"contentUrl" => "https://x.test/b.png"}, nil},
                {:buttons, %{"body" => "Basic", "buttons" => [%{"id" => "a:" <> _ = first}]}},
                {:buttons, %{"body" => "Pro", "buttons" => [%{"id" => second}]}},
                {:media, "image", %{"contentUrl" => "https://x.test/i.png"}, "Info"}
              ]} = Outbound.parts(typed("carousel", payload))

      assert String.ends_with?(first, ":0")
      assert String.ends_with?(second, ":1")
    end

    test "without a prompt the body is the stored fallback" do
      payload = %{"data" => %{"buttons" => labels(2)}}

      assert {:ok, [{:buttons, %{"body" => "Option 1 | Option 2"}}]} =
               Outbound.parts(typed("buttons", payload, "Option 1 | Option 2"))
    end
  end

  test "plain text is one text part" do
    assert {:ok, [{:text, "hi"}]} = Outbound.parts(activity(text: "hi"))
  end

  test "the text is the caption of the first image" do
    assert {:ok, [{:media, "image", _, "look"}, {:media, "image", _, nil}]} =
             Outbound.parts(activity(text: "look", attachments: [image(), image()]))
  end

  test "audio has no caption, so the text is sent first" do
    audio = %{"contentType" => "audio/ogg", "contentUrl" => "https://x.example/v.ogg"}

    assert {:ok, [{:text, "listen"}, {:media, "audio", ^audio, nil}]} =
             Outbound.parts(activity(text: "listen", attachments: [audio]))
  end

  test "media kinds come from the content type, or channelData.whatsappType" do
    kind = fn a -> Outbound.media_kind(a) end

    assert kind.(%{"contentType" => "video/mp4"}) == "video"
    assert kind.(%{"contentType" => "application/pdf"}) == "document"

    assert kind.(%{
             "contentType" => "image/webp",
             "channelData" => %{"whatsappType" => "sticker"}
           }) ==
             "sticker"
  end

  test "a template ignores text and attachments" do
    template = %{"name" => "order_update", "language" => %{"code" => "en_US"}}

    assert {:ok,
            [{:template, %{"name" => "order_update", "language" => "en_US", "components" => []}}]} =
             Outbound.parts(
               activity(text: "x", attachments: [image()], metadata: %{"template" => template})
             )
  end

  test "an invalid template is a permanent error" do
    for template <- [
          %{"name" => "t"},
          %{"language" => "en"},
          "t",
          %{"name" => "t", "language" => "en", "components" => "x"}
        ] do
      assert {:error, %DeliveryError{retryable?: false}} =
               Outbound.parts(activity(metadata: %{"template" => template}))
    end
  end

  test "a buttons card becomes an interactive message with the text as body" do
    card = %{
      "contentType" => Outbound.buttons_type(),
      "content" => %{"buttons" => [%{"id" => "yes", "title" => "Yes"}, %{"title" => "No"}]}
    }

    assert {:ok, [{:buttons, %{"body" => "Confirm?", "buttons" => buttons}}]} =
             Outbound.parts(activity(text: "Confirm?", attachments: [card]))

    assert buttons == [%{"id" => "yes", "title" => "Yes"}, %{"id" => "No", "title" => "No"}]
  end

  test "a buttons card with more than three buttons is rejected" do
    buttons = for i <- 1..4, do: %{"title" => "b#{i}"}
    card = %{"contentType" => Outbound.buttons_type(), "content" => %{"buttons" => buttons}}

    assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
             Outbound.parts(activity(text: "pick", attachments: [card]))

    assert reason =~ "1 to 3 buttons"
  end

  test "a list card needs a button label and rows" do
    card = fn content -> %{"contentType" => Outbound.list_type(), "content" => content} end
    rows = [%{"id" => "a", "title" => "A", "description" => "first"}]

    assert {:ok, [{:list, %{"button" => "Choose", "sections" => [%{"rows" => [_]}]}}]} =
             Outbound.parts(
               activity(
                 text: "Menu",
                 attachments: [card.(%{"button" => "Choose", "sections" => [%{"rows" => rows}]})]
               )
             )

    assert {:error, _} =
             Outbound.parts(
               activity(text: "Menu", attachments: [card.(%{"sections" => [%{"rows" => rows}]})])
             )
  end

  test "location and contacts attachments become their own parts" do
    location = %{
      "contentType" => "application/vnd.converger.location",
      "content" => %{"latitude" => 41.0, "longitude" => 29.0, "name" => "Office"}
    }

    contacts = %{
      "contentType" => "application/vnd.converger.contacts",
      "content" => [%{"name" => "Ada", "phones" => ["+441234"]}]
    }

    assert {:ok, [{:text, "here"}, {:location, _}, {:contacts, [_]}]} =
             Outbound.parts(activity(text: "here", attachments: [location, contacts]))
  end

  test "attachments without a source and unknown cards are not sent" do
    stub = %{"contentType" => "image/jpeg", "channelData" => %{"downloadError" => "too_large"}}
    hero = %{"contentType" => "application/vnd.converger.card.hero", "content" => %{}}

    assert {:ok, [{:text, "t"}]} = Outbound.parts(activity(text: "t", attachments: [stub, hero]))

    assert {:error, %DeliveryError{retryable?: false}} =
             Outbound.parts(activity(attachments: [stub]))
  end
end
