defmodule Converger.Channels.ChatContent do
  @moduledoc """
  Reads the parts of an outbound activity that chat adapters without
  WhatsApp's message-per-part model render (Messenger, Instagram, Viber,
  Discord, Teams):

    * `text/1` - the activity text, else the texts of its card attachments,
      plus a readable line for location and contacts attachments;
    * `buttons/1` - the buttons of its card attachments
      (`application/vnd.converger.card.*`), normalised to
      `%{"title", "payload", "url"}`;
    * `media/1` - the attachments that are files (a `contentUrl` or a
      provider media id), in order;
    * `split/2` - text cut into provider-sized chunks.

  How each adapter maps these to its provider is on its page under
  `docs/channels/`.
  """

  alias Converger.Activities.ActivityAttachment

  @location_type "application/vnd.converger.location"
  @contacts_type "application/vnd.converger.contacts"

  @doc """
  The text of an activity: its `text`, else the title, subtitle, text and
  body of its cards; location and contacts attachments are appended as a
  line each (`"<name>, <address> https://maps.google.com/?q=<lat>,<lon>"`,
  `"<name>: <phones>"`). `""` when there is none.
  """
  def text(activity) do
    attachments = attachments(activity)

    main =
      case blank_to_nil(Map.get(activity, :text)) do
        nil -> card_text(attachments)
        text -> text
      end

    [main | Enum.map(attachments, &well_known_text/1)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @doc """
  The buttons of the activity's cards, in order: `%{"title" => title,
  "payload" => id_or_value_or_title, "url" => url_or_nil}`. An `openUrl`
  button (`type: "openUrl"` with a `value`) has a `"url"`.
  """
  def buttons(activity) do
    for attachment <- attachments(activity),
        card?(attachment),
        button <- List.wrap(attachment["content"]["buttons"]),
        is_map(button),
        title = blank_to_nil(button["title"]),
        not is_nil(title) do
      value = button["value"]
      url = if button["type"] == "openUrl" and is_binary(value), do: value

      %{
        "title" => title,
        "payload" => to_string(button["id"] || blank_to_nil(value) || title),
        "url" => url
      }
    end
  end

  @doc """
  The file attachments of the activity: every attachment that is not a card,
  location or contacts and has a `contentUrl` or a
  `channelData.providerMediaId`.
  """
  def media(activity) do
    for attachment <- attachments(activity),
        not card?(attachment),
        attachment["contentType"] not in ActivityAttachment.well_known_content_types(),
        is_binary(attachment["contentUrl"]) or
          is_binary(get_in(attachment, ["channelData", "providerMediaId"])),
        do: attachment
  end

  @doc """
  The coarse kind of a media attachment from its content type: `"image"`,
  `"video"`, `"audio"` or `"file"`.
  """
  def media_kind(attachment) do
    case attachment["contentType"] do
      "image/" <> _ -> "image"
      "video/" <> _ -> "video"
      "audio/" <> _ -> "audio"
      _ -> "file"
    end
  end

  @doc """
  Splits `text` into chunks of at most `max` characters (graphemes), cutting
  at the last newline or space of a chunk when there is one. `[]` for blank
  text.
  """
  def split(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if String.trim(text) == "", do: [], else: do_split(text, max, [])
  end

  def split(_text, _max), do: []

  defp do_split(text, max, acc) do
    if String.length(text) <= max do
      Enum.reverse([text | acc])
    else
      {head, _rest} = String.split_at(text, max)
      cut = cut_point(head, max)
      {chunk, rest} = String.split_at(text, cut)
      do_split(String.trim_leading(rest), max, [String.trim_trailing(chunk) | acc])
    end
  end

  # The last whitespace in the second half of the chunk, else a hard cut.
  defp cut_point(head, max) do
    graphemes = String.graphemes(head)

    index =
      graphemes
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {g, i} -> if g in ["\n", " "] and i >= div(max, 2), do: i end)

    index || max
  end

  defp attachments(activity),
    do: for(a <- List.wrap(Map.get(activity, :attachments)), is_map(a), do: a)

  defp card?(%{"contentType" => type, "content" => content})
       when is_binary(type) and is_map(content),
       do: String.starts_with?(type, ActivityAttachment.card_prefix())

  defp card?(_attachment), do: false

  defp card_text(attachments) do
    attachments
    |> Enum.filter(&card?/1)
    |> Enum.map(fn %{"content" => content} ->
      [content["title"], content["subtitle"], content["text"], content["body"]]
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.join("\n")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp well_known_text(%{"contentType" => @location_type, "content" => %{} = location}) do
    place =
      [location["name"], location["address"]]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join(", ")

    link =
      if is_number(location["latitude"]) and is_number(location["longitude"]),
        do: "https://maps.google.com/?q=#{location["latitude"]},#{location["longitude"]}"

    [place, link] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
  end

  defp well_known_text(%{"contentType" => @contacts_type, "content" => contacts})
       when is_list(contacts) do
    contacts
    |> Enum.filter(&is_map/1)
    |> Enum.map_join("\n", fn contact ->
      phones = contact |> Map.get("phones") |> List.wrap() |> Enum.filter(&is_binary/1)
      name = contact["name"] || "Contact"
      if phones == [], do: name, else: "#{name}: #{Enum.join(phones, ", ")}"
    end)
  end

  defp well_known_text(_attachment), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
