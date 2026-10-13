defmodule Converger.Activities.MessagePayload do
  @moduledoc """
  Typed message payloads of `message` activities (docs/protocol/messages.md,
  section 4; ADR-0062).

  A persistent Protocol v1 frame other than a plain text turn is stored as a
  `message` activity with

    * `message_type` - the frame type: a type of the rich message vocabulary
      (`card`, `buttons`, ...), a mekik/1-native type (`tool_call`, `genui`,
      `interrupt`, `interrupt_resolved`, `skill`) or an open renderer name
      (mekik/1 section 4.5);
    * `payload` - the frame body, losslessly: every top-level field except
      `type`, `seq` and, for message frames, the envelope fields the server
      owns (`from`, `timestamp`, `sender`, `metadata`, `clientId`, `replyTo`,
      `meta`). A message frame keeps its `id` only when the sender is trusted
      to name it (a bot); a mekik-native frame keeps every field.

  Rebuilding the frame (`to_frame/2`, then the server envelope in
  `ConvergerWeb.Protocol.Frames`) gives back the received frame in canonical
  JSON, except `seq` and the server's `timestamp`.

  Known types are validated against the Protocol v1 JSON Schemas
  (`priv/protocol/v1`); unknown renderer-named types only need an object
  `data`.
  """

  alias Converger.ProtocolSchemas

  @native ~w(tool_call skill genui interrupt interrupt_resolved)
  @vocabulary ~w(text quick-reply buttons card carousel image file video audio location contact)

  # Fields of a message frame that the server owns: never stored in the payload.
  @envelope ~w(type seq from timestamp sender metadata clientId replyTo meta)

  # Stand-ins for the server-owned fields, so a payload validates against the
  # frame schemas.
  @placeholders %{"seq" => 1, "from" => "bot", "timestamp" => 0}

  @doc "mekik/1-native persistent frame types (no message envelope)."
  def native_types, do: @native

  @doc "Message types of the rich message vocabulary (messages.md section 2)."
  def vocabulary, do: @vocabulary

  @doc "Whether `type` is a native or vocabulary type (else an open renderer name)."
  def known?(type), do: type in @native or type in @vocabulary

  @doc "Whether `type` is a mekik/1-native frame type."
  def native?(type), do: type in @native

  @doc """
  Split a persistent frame into what an activity stores.

  Returns `:plain` for a `text` frame that the plain activity columns hold
  (`data` with only `text` and `attachments`, no `actions`, no kept `id`), or
  `{:ok, message_type, payload}`.

  Options: `keep_id: true` keeps a message frame's `id` (a bot naming its
  messages, mekik/1 section 4.5). A client turn's `id` is its clientId and is
  never kept.
  """
  def from_frame(%{"type" => type} = frame, opts \\ []) when is_binary(type) do
    payload =
      if native?(type) do
        Map.drop(frame, ["type", "seq"])
      else
        frame
        |> Map.drop(@envelope)
        |> then(&if(Keyword.get(opts, :keep_id, false), do: &1, else: Map.delete(&1, "id")))
      end

    if plain?(type, payload), do: :plain, else: {:ok, type, payload}
  end

  defp plain?("text", payload) do
    Map.keys(payload) == ["data"] and is_map(payload["data"]) and
      Enum.all?(Map.keys(payload["data"]), &(&1 in ["text", "attachments"])) and
      is_binary(payload["data"]["text"])
  end

  defp plain?(_type, _payload), do: false

  @doc "The stored payload as a frame without the server envelope."
  def to_frame(message_type, payload), do: Map.put(payload, "type", message_type)

  @doc """
  Validate a payload. Returns `:ok` or `{:error, details}`, where `details`
  maps JSON pointers into the frame (`"#/data/buttons/0"`) to messages.
  """
  def validate(message_type, payload) when is_binary(message_type) and is_map(payload) do
    {schema, frame} =
      if native?(message_type) do
        {"frames/server/#{message_type}.schema.json",
         payload |> Map.put("seq", 1) |> Map.put("type", message_type)}
      else
        frame =
          @placeholders
          |> Map.put("id", "placeholder")
          |> Map.merge(Map.drop(payload, Map.keys(@placeholders)))
          |> Map.put("type", message_type)

        {"frames/server/message.schema.json", frame}
      end

    ProtocolSchemas.validate_details(frame, ProtocolSchemas.root!(schema))
  end

  def validate(_message_type, _payload), do: {:error, %{"#" => ["must be an object"]}}

  @doc """
  The plain-text rendering of a payload (`activities.text`, channel
  fallbacks), or nil when it has none worth showing: tool traces, GenUI
  chunks, skills and resolved interrupts.
  """
  def fallback_text(message_type, payload) when is_map(payload) do
    data = if is_map(payload["data"]), do: payload["data"], else: %{}

    message_type
    |> fallback(data, payload)
    |> case do
      text when is_binary(text) -> if String.trim(text) == "", do: nil, else: text
      _ -> nil
    end
  end

  def fallback_text(_message_type, _payload), do: nil

  defp fallback(type, _data, _payload) when type in ~w(tool_call genui skill interrupt_resolved),
    do: nil

  defp fallback("interrupt", data, _payload),
    do: string(get_in(data, ["payload", "title"])) || string(data["text"])

  defp fallback(type, data, payload) when type in ~w(text quick-reply buttons) do
    actions = data["actions"] || data["buttons"] || payload["actions"]
    string(data["text"]) || labels(actions)
  end

  defp fallback("card", data, _payload), do: card_text(data)

  defp fallback("carousel", data, _payload) do
    string(data["text"]) ||
      case data["cards"] do
        [_ | _] = cards -> cards |> Enum.map(&card_text/1) |> join("\n\n")
        _ -> nil
      end
  end

  defp fallback(type, data, _payload) when type in ~w(image video audio),
    do: string(data["text"]) || string(data["caption"]) || string(data["alt"])

  defp fallback("file", data, _payload), do: string(data["text"]) || string(data["name"])

  defp fallback("location", data, _payload) do
    string(data["text"]) || string(data["name"]) || string(data["address"]) ||
      if(is_number(data["latitude"]) and is_number(data["longitude"]),
        do: "#{data["latitude"]}, #{data["longitude"]}"
      )
  end

  defp fallback("contact", data, _payload), do: string(data["text"]) || string(data["name"])

  # Open renderer-named types: `data.text` is the universal fallback (rule 3).
  defp fallback(_type, data, _payload), do: string(data["text"])

  defp card_text(%{} = card) do
    [card["title"], card["subtitle"], card["text"]]
    |> Enum.map(&string/1)
    |> join("\n")
  end

  defp card_text(_card), do: nil

  defp labels([_ | _] = actions) do
    actions
    |> Enum.map(&(is_map(&1) && string(&1["label"])))
    |> Enum.filter(&is_binary/1)
    |> join(" | ")
  end

  defp labels(_actions), do: nil

  defp join(parts, separator) do
    case Enum.filter(parts, &is_binary/1) do
      [] -> nil
      parts -> Enum.join(parts, separator)
    end
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil
end
