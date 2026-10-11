defmodule Converger.Channels.WhatsApp.OutboundTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.DeliveryError
  alias Converger.Channels.WhatsApp.Outbound

  defp activity(attrs) do
    Map.merge(%{text: nil, attachments: [], metadata: %{}}, Map.new(attrs))
  end

  defp image(url \\ "https://cdn.example.com/a.jpg"),
    do: %{"contentType" => "image/jpeg", "contentUrl" => url}

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
