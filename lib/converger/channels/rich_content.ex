defmodule Converger.Channels.RichContent do
  @moduledoc """
  Reads typed messages (`message_type` + `payload`, #68, ADR-0062) for the
  end-user channel adapters, and renders them where a channel has nothing
  better (docs/protocol/messages.md, sections 5 and 6; ADR-0064).

    * `actions/2` - every action of a message (`text` + `actions`,
      `quick-reply`, `buttons`, `card`, `carousel`, `interrupt`) in one flat,
      indexed list: `%{"index", "number", "label", "value", "url", "card"}`.
      `index` is the position in that list (what answer keys name), `number`
      the 1-based position among the answerable actions (links have none):
      what a numbered list shows and a numeric reply picks.
    * `prompt/2`, `cards/2`, `card_text/1` - the texts around the actions.
    * `text/1`, `html/1` - the universal rendering: the prompt, then the
      answerable actions as a numbered list (`1. Track an order`), links as
      `label: url`, cards one block each, media as their caption and link.
      Used for every channel that does not render a type natively (SMS,
      Messenger, ...) and for email.
    * `attachment/2` - a media, location or contact message as a legacy
      attachment (`contentUrl`, `application/vnd.converger.location`, ...),
      which the adapters that declare those types already render natively.
    * `ref/2`, `parse_ref/1`, `answer/2`, `numeric/1` - answer keys and the
      normalised answer of section 6.
    * `truncate/2` - provider label limits, with an ellipsis.
  """

  alias Converger.Activities.MessagePayload

  @actionable ~w(text quick-reply buttons card carousel interrupt)
  @media ~w(image file video audio)
  @well_known ~w(location contact)

  @max_cards 10

  @location_type "application/vnd.converger.location"
  @contacts_type "application/vnd.converger.contacts"

  @ref ~r/\Aa:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}):(\d{1,4})\z/
  @numeric ~r/\A\s*(\d{1,3})\s*[.)]?\s*\z/

  @doc "Message types that can carry actions."
  def actionable_types, do: @actionable

  @doc "Media message types: delivered as a file attachment where the channel renders it."
  def media_types, do: @media

  @doc "Location and contact: delivered as the well-known attachments where the channel renders them."
  def well_known_types, do: @well_known

  @doc "Whether the activity is a typed message (`message_type` and a `payload`)."
  def typed?(activity),
    do: is_binary(Map.get(activity, :message_type)) and is_map(Map.get(activity, :payload))

  @doc """
  Whether an end-user channel gets nothing for this typed message whatever it
  renders: an `interrupt` with a `tool` or an `event` (it is answered by the
  client runtime, not by a person).
  """
  def skip?(%{message_type: "interrupt", payload: payload}) when is_map(payload) do
    data = data(payload)
    not is_nil(data["tool"]) or not is_nil(data["event"])
  end

  def skip?(_activity), do: false

  ## Reading

  @doc "The actions of a typed payload (see the module doc). `[]` for other types."
  def actions(message_type, payload) when is_map(payload) do
    data = data(payload)

    message_type
    |> raw_actions(data, payload)
    |> Enum.flat_map(fn {card, actions} ->
      for action <- List.wrap(actions), is_map(action), label = string(action["label"]) do
        %{
          "label" => label,
          "value" => action["value"],
          "url" => string(action["url"]),
          "card" => card
        }
      end
    end)
    |> Enum.with_index()
    |> Enum.map_reduce(0, fn {action, index}, number ->
      if action["url"],
        do: {Map.merge(action, %{"index" => index, "number" => nil}), number},
        else: {Map.merge(action, %{"index" => index, "number" => number + 1}), number + 1}
    end)
    |> elem(0)
  end

  def actions(_message_type, _payload), do: []

  defp raw_actions("text", data, payload), do: [{nil, payload["actions"] || data["actions"]}]

  defp raw_actions("quick-reply", data, payload),
    do: [{nil, data["actions"] || payload["actions"]}]

  defp raw_actions("buttons", data, payload), do: [{nil, data["buttons"] || payload["actions"]}]
  defp raw_actions("interrupt", data, _payload), do: [{nil, data["actions"]}]
  defp raw_actions("card", data, _payload), do: [{0, data["buttons"] || data["actions"]}]

  defp raw_actions("carousel", data, _payload) do
    for {card, index} <- Enum.with_index(cards("carousel", %{"data" => data})),
        do: {index, card["buttons"] || card["actions"]}
  end

  defp raw_actions(_type, _data, _payload), do: []

  @doc "The answerable actions (no links), in order."
  def choices(actions), do: Enum.filter(actions, & &1["number"])

  @doc "The actions of a stored activity (`[]` for a plain or non-actionable one)."
  def activity_actions(activity) do
    if typed?(activity) and activity.message_type in @actionable,
      do: actions(activity.message_type, activity.payload),
      else: []
  end

  @doc """
  The text that goes with the actions: `data.text`; an interrupt's
  `payload.title` (else `data.text`); a card's title, subtitle and text.
  """
  def prompt(message_type, payload) when is_map(payload) do
    data = data(payload)

    case message_type do
      "interrupt" -> string(get_in(data, ["payload", "title"])) || string(data["text"])
      "card" -> card_text(data)
      type when type in ~w(text quick-reply buttons carousel) -> string(data["text"])
      type -> MessagePayload.fallback_text(type, payload)
    end
  end

  def prompt(_message_type, _payload), do: nil

  @doc "The cards of a `card` (one) or `carousel` (at most 10) payload."
  def cards("card", payload) when is_map(payload), do: [data(payload)]

  def cards("carousel", payload) when is_map(payload) do
    data(payload)["cards"] |> List.wrap() |> Enum.filter(&is_map/1) |> Enum.take(@max_cards)
  end

  def cards(_message_type, _payload), do: []

  @doc "A card's title, subtitle and text, one per line, or nil."
  def card_text(card) when is_map(card) do
    [card["title"], card["subtitle"], card["text"]]
    |> Enum.map(&string/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  def card_text(_card), do: nil

  @doc "An absolute `http(s)` URL or a Converger attachment path, else nil."
  def media_url(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "/api/v1/converger/attachments/") -> url
      http_url?(url) -> url
      true -> nil
    end
  end

  def media_url(_url), do: nil

  ## Rendering as text

  @doc """
  The plain-text rendering of a typed activity (the module doc), or nil when
  it has nothing to show (falls back to the stored text fallback).
  """
  def text(activity) do
    if typed?(activity) do
      activity.message_type
      |> blocks(activity.payload)
      |> Enum.map(&block_text/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> case do
        [] -> blank_to_nil(Map.get(activity, :text))
        parts -> Enum.join(parts, "\n\n")
      end
    else
      blank_to_nil(Map.get(activity, :text))
    end
  end

  @doc """
  The HTML rendering of a typed activity for email: paragraphs, numbered
  lists (`<ol>`), links and card images. Nil like `text/1`.
  """
  def html(activity) do
    if typed?(activity) do
      activity.message_type
      |> blocks(activity.payload)
      |> Enum.map(&block_html/1)
      |> Enum.reject(&(&1 == ""))
      |> case do
        [] -> nil
        parts -> Enum.join(parts, "\n")
      end
    end
  end

  # A block: %{text, image, choices, links}. Cards are one block each.
  defp blocks(type, payload) when type in @actionable do
    actions = actions(type, payload)

    case cards(type, payload) do
      [] ->
        [block(prompt(type, payload), nil, actions)]

      cards ->
        intro = if type == "carousel", do: [block(prompt(type, payload), nil, [])], else: []

        cards_blocks =
          for {card, index} <- Enum.with_index(cards) do
            block(
              card_text(card),
              media_url(card["image"]),
              Enum.filter(actions, &(&1["card"] == index))
            )
          end

        intro ++ cards_blocks
    end
  end

  defp blocks(type, payload) when type in @media do
    data = data(payload)
    caption = string(data["caption"]) || string(data["text"]) || string(data["alt"])
    url = media_url(data["src"] || data["url"])
    name = string(data["name"])

    text =
      case {caption, name} do
        {nil, nil} -> nil
        {nil, name} -> name
        {caption, _} -> caption
      end

    [
      %{
        text: text,
        image: nil,
        choices: [],
        links: if(http_url?(url), do: [{name || url, url}], else: [])
      }
    ]
  end

  defp blocks("location", payload) do
    data = data(payload)

    place =
      [data["name"], data["address"]]
      |> Enum.map(&string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    link = map_link(data)
    text = blank_to_nil(place) || string(data["text"])
    [%{text: text, image: nil, choices: [], links: if(link, do: [{link, link}], else: [])}]
  end

  defp blocks("contact", payload) do
    data = data(payload)

    {_caption, %{"content" => [contact]}} = attachment("contact", payload)
    details = contact["phones"] ++ (contact["emails"] || [])

    name = string(data["name"]) || "Contact"
    text = if details == [], do: name, else: "#{name}: #{Enum.join(details, ", ")}"
    [%{text: text, image: nil, choices: [], links: []}]
  end

  defp blocks(type, payload),
    do: [%{text: MessagePayload.fallback_text(type, payload), image: nil, choices: [], links: []}]

  defp block(text, image, actions) do
    %{
      text: text,
      image: image,
      choices: for(a <- choices(actions), do: {a["number"], a["label"]}),
      links: for(a <- actions, a["url"], do: {a["label"], a["url"]})
    }
  end

  defp block_text(%{text: text, image: image, choices: choices, links: links}) do
    [
      text,
      if(http_url?(image), do: image),
      Enum.map_join(choices, "\n", fn {n, label} -> "#{n}. #{label}" end),
      Enum.map_join(links, "\n", fn
        {url, url} -> url
        {label, url} -> "#{label}: #{url}"
      end)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp block_html(%{text: text, image: image, choices: choices, links: links}) do
    paragraph =
      if text, do: "<p>" <> (text |> escape() |> String.replace(~r/\r?\n/, "<br>\n")) <> "</p>"

    image =
      if http_url?(image),
        do: ~s(<p><img src="#{escape(image)}" alt="" style="max-width:100%"></p>)

    list =
      case choices do
        [] ->
          nil

        [{first, _} | _] ->
          items = Enum.map_join(choices, "\n", fn {_n, label} -> "<li>#{escape(label)}</li>" end)
          ~s(<ol start="#{first}">\n#{items}\n</ol>)
      end

    links =
      for {label, url} <- links, do: ~s(<p><a href="#{escape(url)}">#{escape(label)}</a></p>)

    [paragraph, image, list | links]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp map_link(%{"latitude" => lat, "longitude" => lon}) when is_number(lat) and is_number(lon),
    do: "https://maps.google.com/?q=#{lat},#{lon}"

  defp map_link(data), do: if(http_url?(data["url"]), do: data["url"])

  ## Rendering as a legacy attachment

  @doc """
  A media, location or contact payload as the legacy attachment the channel
  adapters render (ADR-0039): `{caption, attachment}`, or nil when the
  payload has no usable source.
  """
  def attachment(type, payload) when type in @media and is_map(payload) do
    data = data(payload)
    url = media_url(data["src"] || data["url"])

    if url do
      caption = string(data["caption"]) || string(data["text"])

      attachment =
        %{"contentType" => content_type(type, data, url), "contentUrl" => url}
        |> put_present("name", string(data["name"]))
        |> put_present("channelData", if(data["voice"] == true, do: %{"voice" => true}))

      {caption, attachment}
    end
  end

  def attachment("location", payload) when is_map(payload) do
    data = data(payload)

    if is_number(data["latitude"]) and is_number(data["longitude"]) do
      content =
        Map.take(data, ~w(latitude longitude name address url))
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      {nil, %{"contentType" => @location_type, "content" => content}}
    end
  end

  def attachment("contact", payload) when is_map(payload) do
    data = data(payload)
    phones = for p <- List.wrap(data["phones"]), is_map(p), n = string(p["number"]), do: n
    emails = for e <- List.wrap(data["emails"]), is_map(e), a = string(e["address"]), do: a

    contact =
      %{"name" => string(data["name"]) || "Contact", "phones" => phones}
      |> put_present("emails", if(emails != [], do: emails))

    {nil, %{"contentType" => @contacts_type, "content" => [contact]}}
  end

  def attachment(_type, _payload), do: nil

  @default_mime %{
    "image" => "image/jpeg",
    "video" => "video/mp4",
    "audio" => "audio/mpeg",
    "file" => "application/octet-stream"
  }

  defp content_type(type, data, url) do
    declared = string(data["mimeType"])
    guessed = MIME.from_path(URI.parse(string(data["name"]) || url).path || "")

    cond do
      declared -> declared
      type == "file" -> guessed
      String.starts_with?(guessed, type <> "/") -> guessed
      true -> @default_mime[type]
    end
  end

  ## Answers (section 6)

  @doc """
  The answer key of action `index` of activity `id`: `"a:<id>:<index>"`
  (at most 41 bytes, so it fits Telegram's 64-byte `callback_data`).
  """
  def ref(activity_id, index), do: "a:#{activity_id}:#{index}"

  @doc "`{:ok, activity_id, index}` for an answer key, else `:error`."
  def parse_ref(value) when is_binary(value) do
    case Regex.run(@ref, value) do
      [_, id, index] -> {:ok, String.downcase(id), String.to_integer(index)}
      nil -> :error
    end
  end

  def parse_ref(_value), do: :error

  @doc """
  Adds the `"answer"` an inbound message carries when a provider reply names
  an answer key (`Converger.Inbound.Answers`); the message is unchanged
  otherwise. `label` is the provider's title of the tapped button, the text
  kept when the key does not resolve.
  """
  def put_answer(message, ref, source, label \\ nil) do
    case parse_ref(ref) do
      {:ok, _id, _index} ->
        Map.put(message, "answer", %{"ref" => ref, "source" => source, "label" => label})

      :error ->
        message
    end
  end

  @doc "`{:ok, n}` when `text` is a numeric reply (`2`, `2.`, `2)`), else `:error`."
  def numeric(text) when is_binary(text) do
    case Regex.run(@numeric, text) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> :error
    end
  end

  def numeric(_text), do: :error

  @doc """
  The normalised answer to `action`: `{text, metadata_action}`. The text is
  the action's `value` when it is a non-empty string, else its `label`;
  `metadata_action` is `%{"label", "value", "source"}` (`value` defaults to
  the label, non-string values are kept as they are).
  """
  def answer(action, source) do
    label = action["label"]
    value = if is_nil(action["value"]), do: label, else: action["value"]
    text = if is_binary(value) and value != "", do: value, else: label
    {text, %{"label" => label, "value" => value, "source" => source}}
  end

  @doc "`text` cut to `max` characters, the last one an ellipsis when cut."
  def truncate(text, max) when is_binary(text) and is_integer(max) and max > 1 do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max - 1) <> "…"
  end

  def truncate(text, _max), do: text

  ## Helpers

  defp data(payload), do: if(is_map(payload["data"]), do: payload["data"], else: %{})

  defp http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _ ->
        false
    end
  end

  defp http_url?(_url), do: false

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp string(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp string(_value), do: nil

  defp blank_to_nil(value), do: string(value)
end
