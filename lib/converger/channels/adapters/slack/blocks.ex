defmodule Converger.Channels.Adapters.Slack.Blocks do
  @moduledoc """
  Renders `application/vnd.converger.card.*` attachments as Slack Block Kit.

  A card (`{title, subtitle?, image?, text?, buttons?}`, see
  `docs/protocol/messages.md`) becomes:

    * a `section` with `*title*`, the subtitle and the text as `mrkdwn`, and
      the image as its accessory;
    * an `actions` block with one button per card button: a `url` button
      opens the link, any other button sends its `value` (or label) back as
      a `block_actions` interaction, which the adapter turns into an inbound
      message.

  Slack limits are applied by truncation: 3000 characters per section text,
  75 per button label, 2000 per button value, 25 elements per actions block
  and 50 blocks per message.
  """

  alias Converger.Activities.ActivityAttachment
  alias Converger.Channels.RichContent

  @max_blocks 50
  @max_section_text 3000
  @max_button_text 75
  @max_button_value 2000
  @max_actions 25

  @doc "Block Kit blocks for the card attachments of `attachments` (`[]` when there are none)."
  def from_attachments(attachments) do
    attachments
    |> List.wrap()
    |> Enum.filter(&card?/1)
    |> Enum.with_index()
    |> Enum.flat_map(fn {attachment, index} -> card_blocks(attachment["content"], index) end)
    |> Enum.take(@max_blocks)
  end

  @doc "Whether an attachment is a card (`application/vnd.converger.card.*` with object content)."
  def card?(%{"contentType" => type, "content" => content})
      when is_binary(type) and is_map(content),
      do: String.starts_with?(type, ActivityAttachment.card_prefix())

  def card?(_attachment), do: false

  @doc """
  Block Kit blocks for a typed message with actions (#68, ADR-0064): `text`
  + `actions`, `quick-reply`, `buttons` and `interrupt` as a section with the
  prompt and an actions block; `card` and `carousel` as above, one card after
  the other. Button values are answer keys (`RichContent.ref/2`), so a click
  comes back as the normalised answer. `[]` for other activities.
  """
  def from_message(%{message_type: type, payload: payload} = activity)
      when is_binary(type) and is_map(payload) do
    actions = RichContent.actions(type, payload)

    blocks =
      case RichContent.cards(type, payload) do
        [] ->
          prompt_blocks(RichContent.prompt(type, payload), actions, activity)

        cards ->
          intro =
            if type == "carousel",
              do: prompt_blocks(RichContent.prompt(type, payload), [], activity),
              else: []

          intro ++
            Enum.flat_map(Enum.with_index(cards), fn {card, index} ->
              card_actions = Enum.filter(actions, &(&1["card"] == index))
              card_section(card) ++ actions_block(card_actions, activity)
            end)
      end

    Enum.take(blocks, @max_blocks)
  end

  def from_message(_activity), do: []

  defp prompt_blocks(text, actions, activity) do
    section =
      case text do
        nil ->
          []

        text ->
          [
            %{
              type: "section",
              text: %{type: "mrkdwn", text: String.slice(text, 0, @max_section_text)}
            }
          ]
      end

    section ++ actions_block(actions, activity)
  end

  defp actions_block([], _activity), do: []

  defp actions_block(actions, activity) do
    elements =
      actions
      |> Enum.map(fn action ->
        element = %{
          type: "button",
          action_id: "converger_a_#{action["index"]}",
          text: %{
            type: "plain_text",
            text: RichContent.truncate(action["label"], @max_button_text)
          }
        }

        if action["url"],
          do: Map.put(element, :url, action["url"]),
          else: Map.put(element, :value, RichContent.ref(activity.id, action["index"]))
      end)
      |> Enum.take(@max_actions)

    [%{type: "actions", elements: elements}]
  end

  defp card_section(card) do
    section =
      case section_text(card) do
        "" -> nil
        text -> %{type: "section", text: %{type: "mrkdwn", text: text}}
      end

    case {section, RichContent.media_url(card["image"])} do
      {nil, nil} -> []
      {nil, "/" <> _} -> []
      {nil, image} -> [%{type: "image", image_url: image, alt_text: alt_text(card)}]
      {section, nil} -> [section]
      {section, "/" <> _} -> [section]
      {section, image} -> [Map.put(section, :accessory, image_element(image, card))]
    end
  end

  defp card_blocks(card, index) do
    section =
      case section_text(card) do
        "" -> nil
        text -> %{type: "section", text: %{type: "mrkdwn", text: text}}
      end

    section =
      case {section, string(card["image"])} do
        {nil, nil} -> nil
        {nil, image} -> %{type: "image", image_url: image, alt_text: alt_text(card)}
        {section, nil} -> section
        {section, image} -> Map.put(section, :accessory, image_element(image, card))
      end

    buttons =
      card["buttons"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.with_index()
      |> Enum.flat_map(fn {button, i} -> button_element(button, index, i) end)
      |> Enum.take(@max_actions)

    actions = if buttons != [], do: %{type: "actions", elements: buttons}

    Enum.reject([section, actions], &is_nil/1)
  end

  defp section_text(card) do
    title = string(card["title"])

    [title && "*#{title}*", string(card["subtitle"]), string(card["text"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.slice(0, @max_section_text)
  end

  defp image_element(url, card), do: %{type: "image", image_url: url, alt_text: alt_text(card)}

  defp alt_text(card), do: string(card["title"]) || "image"

  defp button_element(button, card_index, button_index) do
    case string(button["label"]) do
      nil ->
        []

      label ->
        element = %{
          type: "button",
          action_id: "converger_#{card_index}_#{button_index}",
          text: %{type: "plain_text", text: String.slice(label, 0, @max_button_text)}
        }

        case string(button["url"]) do
          nil -> [Map.put(element, :value, button_value(button, label))]
          url -> [Map.put(element, :url, url)]
        end
    end
  end

  # Button values may be any JSON (e.g. `{"approved": true}`); Slack values
  # are strings, so non-strings travel JSON-encoded.
  defp button_value(button, label) do
    case button["value"] do
      nil -> label
      value when is_binary(value) -> value
      value -> Jason.encode!(value)
    end
    |> String.slice(0, @max_button_value)
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil
end
