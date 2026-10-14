defmodule Converger.Channels.WhatsApp.Outbound do
  @moduledoc """
  Plans the WhatsApp messages an activity becomes. Shared by the
  `whatsapp_meta` and `whatsapp_infobip` adapters, which render each part in
  their provider's request shape.

  WhatsApp sends one piece of content per message, so an activity can become
  several parts, sent in order:

    * `metadata.template` (`%{"name", "language", "components"}`) - a
      template (HSM) message. Templates are the only messages WhatsApp
      accepts outside the 24-hour customer-service window. The activity's
      text and attachments are ignored.
    * a typed message with actions (`text` + `actions`, `quick-reply`,
      `buttons`, `card`, `carousel`, `interrupt`; #68, ADR-0064): reply
      buttons (1 to 3 actions, titles cut to 20 characters), a list message
      (4 to 10, rows cut to 24 with the full label as description) or a
      numbered text (more); links are appended to the body (cut to 1024). A
      card is its image, then its text with its buttons; a carousel one card
      after the other. Button and row ids are answer keys
      (`Converger.Channels.RichContent.ref/2`).
    * otherwise, in attachment order:
      * `application/vnd.converger.card.buttons` / `.card.list` -
        an interactive reply-button or list message;
      * `application/vnd.converger.location` / `.contacts` - a location or
        contacts message;
      * any other attachment with a `contentUrl` (or a provider media id in
        `channelData`) - an image, video, audio, document or sticker message;
      * other card types and attachments without a source are not sent.
    * the activity's `text` is the caption of the first image, video or
      document, or the body of the first interactive message; otherwise it is
      sent first, as a text message.

  See `docs/channels/whatsapp.md` and ADR-0039.
  """

  alias Converger.Channels.{DeliveryError, RichContent}
  alias Converger.Uploads
  alias Converger.Uploads.Attachment

  @buttons_type "application/vnd.converger.card.buttons"
  @list_type "application/vnd.converger.card.list"
  @location_type "application/vnd.converger.location"
  @contacts_type "application/vnd.converger.contacts"
  @card_prefix "application/vnd.converger.card."

  @captioned ~w(image video document)
  @kinds ~w(image video audio document sticker)

  @max_buttons 3
  @max_list_rows 10

  # Cloud API limits (docs/protocol/messages.md section 5).
  @max_button_title 20
  @max_row_title 24
  @max_row_description 72
  @max_body 1024
  @list_button "Options"

  @type part ::
          {:text, String.t()}
          | {:template, map()}
          | {:media, String.t(), map(), String.t() | nil}
          | {:location, map()}
          | {:contacts, [map()]}
          | {:buttons, map()}
          | {:list, map()}

  @doc "Content type of an interactive reply-button card."
  def buttons_type, do: @buttons_type

  @doc "Content type of an interactive list card."
  def list_type, do: @list_type

  @doc """
  The parts of an activity, in sending order. `{:error, %DeliveryError{}}`
  (permanent) for an invalid template or interactive card, or an activity
  with nothing WhatsApp can render.
  """
  @spec parts(map()) :: {:ok, [part()]} | {:error, DeliveryError.t()}
  def parts(activity) do
    metadata = Map.get(activity, :metadata) || %{}

    cond do
      metadata["template"] -> template_part(metadata["template"])
      RichContent.typed?(activity) -> rich_parts(activity)
      true -> content_parts(activity)
    end
  end

  # A typed message the adapter declares (#68, ADR-0064; media, location and
  # contact arrive as legacy attachments, see Converger.Activities.Downgrade):
  # actions become reply buttons (1 to 3), a list (4 to 10) or a numbered
  # text (more); every button and row id is the answer key
  # `RichContent.ref/2`. A card is its image, then its text with its buttons;
  # a carousel one card after the other (at most 10).
  defp rich_parts(%{message_type: type, payload: payload} = activity) do
    actions = RichContent.actions(type, payload)
    fallback = blank_to_nil(Map.get(activity, :text))

    parts =
      case RichContent.cards(type, payload) do
        [] ->
          interactive_parts(RichContent.prompt(type, payload) || fallback, actions, activity)

        cards ->
          intro =
            if type == "carousel",
              do: text_parts(RichContent.prompt(type, payload)),
              else: []

          intro ++
            Enum.flat_map(Enum.with_index(cards), fn {card, index} ->
              card_parts(card, Enum.filter(actions, &(&1["card"] == index)), activity)
            end)
      end

    finish(parts)
  end

  defp card_parts(card, actions, activity) do
    text = RichContent.card_text(card)

    image =
      case RichContent.media_url(card["image"]) do
        nil -> nil
        url -> %{"contentType" => "image/jpeg", "contentUrl" => url}
      end

    cond do
      actions == [] and image -> [{:media, "image", image, text}]
      actions == [] -> text_parts(text)
      image -> [{:media, "image", image, nil} | interactive_parts(text, actions, activity)]
      true -> interactive_parts(text, actions, activity)
    end
  end

  defp interactive_parts(text, actions, activity) do
    choices = RichContent.choices(actions)
    links = for a <- actions, a["url"], do: "#{a["label"]}: #{a["url"]}"
    body = [text | links] |> Enum.reject(&is_nil/1) |> Enum.join("\n") |> blank_to_nil()
    body_or_labels = body || Enum.map_join(choices, " | ", & &1["label"])

    cond do
      choices == [] ->
        text_parts(body)

      length(choices) <= @max_buttons ->
        [{:buttons, interactive_card(body_or_labels, %{"buttons" => buttons(choices, activity)})}]

      length(choices) <= @max_list_rows ->
        [{:list, interactive_card(body_or_labels, list_action(choices, activity))}]

      true ->
        numbered = Enum.map_join(choices, "\n", &"#{&1["number"]}. #{&1["label"]}")
        text_parts(Enum.join(Enum.reject([body, numbered], &is_nil/1), "\n\n"))
    end
  end

  defp buttons(choices, activity) do
    for c <- choices do
      %{
        "id" => RichContent.ref(activity.id, c["index"]),
        "title" => RichContent.truncate(c["label"], @max_button_title)
      }
    end
  end

  defp list_action(choices, activity) do
    rows = for c <- choices, do: list_row(c, activity)
    %{"button" => @list_button, "sections" => [%{"title" => nil, "rows" => rows}]}
  end

  # A row title is at most 24 characters; a longer label is shown in full
  # (up to 72) as the row description.
  defp list_row(choice, activity) do
    label = choice["label"]
    title = RichContent.truncate(label, @max_row_title)

    %{
      "id" => RichContent.ref(activity.id, choice["index"]),
      "title" => title,
      "description" => if(title != label, do: RichContent.truncate(label, @max_row_description))
    }
  end

  defp interactive_card(body, action) do
    Map.merge(
      %{"body" => RichContent.truncate(body, @max_body), "header" => nil, "footer" => nil},
      action
    )
  end

  defp text_parts(nil), do: []
  defp text_parts(text), do: [{:text, text}]

  defp template_part(%{"name" => name} = template) when is_binary(name) and name != "" do
    case language_code(template["language"]) do
      nil ->
        permanent("metadata.template.language is required (a code such as \"en_US\")")

      code ->
        components = template["components"]

        if is_nil(components) or is_list(components) do
          {:ok,
           [
             {:template,
              template
              |> Map.put("language", code)
              |> Map.put("components", components || [])}
           ]}
        else
          permanent("metadata.template.components must be a list")
        end
    end
  end

  defp template_part(_template),
    do: permanent("metadata.template must be an object with a \"name\"")

  defp language_code(code) when is_binary(code) and code != "", do: code
  defp language_code(%{"code" => code}) when is_binary(code) and code != "", do: code
  defp language_code(_), do: nil

  defp content_parts(activity) do
    text = blank_to_nil(Map.get(activity, :text))
    attachments = for a <- List.wrap(Map.get(activity, :attachments)), is_map(a), do: a

    result =
      Enum.reduce_while(attachments, {[], text}, fn attachment, {parts, text} ->
        case attachment_part(attachment, text) do
          {:ok, nil, text} -> {:cont, {parts, text}}
          {:ok, part, text} -> {:cont, {[part | parts], text}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:error, _} = error ->
        error

      {parts, nil} ->
        finish(Enum.reverse(parts))

      {parts, text} ->
        finish([{:text, text} | Enum.reverse(parts)])
    end
  end

  defp finish([]),
    do: permanent("nothing to send: the activity has no text and no sendable attachments")

  defp finish(parts), do: {:ok, parts}

  # Returns {:ok, part | nil, remaining_text} or {:error, _}.
  defp attachment_part(%{"contentType" => @buttons_type} = attachment, text) do
    with {:ok, card} <- buttons_card(attachment["content"], text) do
      {:ok, {:buttons, card}, nil}
    end
  end

  defp attachment_part(%{"contentType" => @list_type} = attachment, text) do
    with {:ok, card} <- list_card(attachment["content"], text) do
      {:ok, {:list, card}, nil}
    end
  end

  defp attachment_part(%{"contentType" => @location_type, "content" => content}, text)
       when is_map(content) do
    if is_number(content["latitude"]) and is_number(content["longitude"]),
      do: {:ok, {:location, content}, text},
      else: permanent("location attachment needs numeric latitude and longitude")
  end

  defp attachment_part(%{"contentType" => @contacts_type, "content" => contacts}, text)
       when is_list(contacts) do
    {:ok, {:contacts, Enum.filter(contacts, &is_map/1)}, text}
  end

  defp attachment_part(%{"contentType" => @card_prefix <> _}, text), do: {:ok, nil, text}

  defp attachment_part(attachment, text) do
    if has_source?(attachment) do
      kind = media_kind(attachment)

      if kind in @captioned and text,
        do: {:ok, {:media, kind, attachment, text}, nil},
        else: {:ok, {:media, kind, attachment, nil}, text}
    else
      {:ok, nil, text}
    end
  end

  defp has_source?(attachment) do
    is_binary(attachment["contentUrl"]) or
      is_binary(get_in(attachment, ["channelData", "providerMediaId"]))
  end

  @doc """
  The WhatsApp message kind of a media attachment: `channelData.whatsappType`
  when set (e.g. `"sticker"`), else from the content type (`image/*`,
  `video/*`, `audio/*`), else `"document"`.
  """
  def media_kind(attachment) do
    case get_in(attachment, ["channelData", "whatsappType"]) do
      kind when kind in @kinds ->
        kind

      _ ->
        case attachment["contentType"] do
          "image/" <> _ -> "image"
          "video/" <> _ -> "video"
          "audio/" <> _ -> "audio"
          _ -> "document"
        end
    end
  end

  defp buttons_card(content, text) when is_map(content) do
    body = blank_to_nil(content["body"]) || text
    buttons = for b <- List.wrap(content["buttons"]), is_map(b), do: button(b)

    cond do
      is_nil(body) ->
        permanent("buttons card needs a body (content.body or the activity text)")

      buttons == [] or length(buttons) > @max_buttons ->
        permanent("buttons card needs 1 to #{@max_buttons} buttons")

      Enum.any?(buttons, &is_nil(&1["title"])) ->
        permanent("every button needs a title")

      true ->
        {:ok, Map.merge(card_texts(content), %{"body" => body, "buttons" => buttons})}
    end
  end

  defp buttons_card(_content, _text), do: permanent("buttons card content must be an object")

  defp button(b) do
    title = blank_to_nil(b["title"])
    %{"id" => to_string(b["id"] || title), "title" => title}
  end

  defp list_card(content, text) when is_map(content) do
    body = blank_to_nil(content["body"]) || text
    sections = list_sections(content["sections"])
    rows = Enum.flat_map(sections, & &1["rows"])

    cond do
      is_nil(body) ->
        permanent("list card needs a body (content.body or the activity text)")

      is_nil(blank_to_nil(content["button"])) ->
        permanent("list card needs a button label (content.button)")

      rows == [] or length(rows) > @max_list_rows ->
        permanent("list card needs 1 to #{@max_list_rows} rows")

      true ->
        {:ok,
         Map.merge(card_texts(content), %{
           "body" => body,
           "button" => content["button"],
           "sections" => sections
         })}
    end
  end

  defp list_card(_content, _text), do: permanent("list card content must be an object")

  defp list_sections(sections) do
    for s <- List.wrap(sections), is_map(s) do
      rows =
        for r <- List.wrap(s["rows"]), is_map(r) do
          %{
            "id" => to_string(r["id"] || r["title"]),
            "title" => r["title"],
            "description" => r["description"]
          }
        end

      %{"title" => s["title"], "rows" => rows}
    end
  end

  defp card_texts(content) do
    %{"header" => blank_to_nil(content["header"]), "footer" => blank_to_nil(content["footer"])}
  end

  @doc """
  Where the bytes of a media attachment come from:

    * `{:stored, %Attachment{}}` - a file uploaded to Converger
      (`contentUrl` is this server's `/api/v1/converger/attachments/:id`,
      of the channel's tenant);
    * `{:provider_id, id}` - a media id of the same provider
      (`channelData.providerMediaId` with `channelData.provider == provider`);
    * `{:link, url}` - any other `http(s)` URL, fetched by the provider.

  `{:error, %DeliveryError{}}` (permanent) for a Converger attachment that
  does not exist or belongs to another tenant, or no usable source.
  """
  def media_source(channel, attachment, provider) do
    url = attachment["contentUrl"]
    channel_data = attachment["channelData"] || %{}

    cond do
      id = stored_attachment_id(url) ->
        stored_attachment(channel, id)

      channel_data["provider"] == provider and is_binary(channel_data["providerMediaId"]) ->
        {:provider_id, channel_data["providerMediaId"]}

      http_url?(url) ->
        {:link, url}

      true ->
        permanent("attachment has no usable contentUrl")
    end
  end

  defp stored_attachment(channel, id) do
    case Uploads.get_attachment(channel.tenant_id, id) do
      %Attachment{} = stored -> {:stored, stored}
      nil -> permanent("attachment #{id} not found")
    end
  end

  @attachment_path ~r"\A/api/v1/converger/attachments/([0-9a-fA-F-]{36})\z"

  defp stored_attachment_id(url) when is_binary(url) do
    uri = URI.parse(url)

    local? =
      is_nil(uri.host) or
        (uri.host == URI.parse(ConvergerWeb.Endpoint.url()).host and is_nil(uri.query))

    with true <- local?,
         [_, id] <- Regex.run(@attachment_path, uri.path || "") do
      id
    else
      _ -> nil
    end
  end

  defp stored_attachment_id(_url), do: nil

  defp http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _ ->
        false
    end
  end

  defp http_url?(_url), do: false

  @doc """
  Text of the `outside_window` delivery error: the provider rejected a
  free-form message because the customer has not written in 24 hours.
  """
  def outside_window_message(detail) do
    "outside_window: the customer has not messaged in the last 24 hours, so WhatsApp " <>
      "only accepts template messages; send an approved template in metadata.template " <>
      "(#{detail})"
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp permanent(message), do: {:error, DeliveryError.permanent(message)}
end
