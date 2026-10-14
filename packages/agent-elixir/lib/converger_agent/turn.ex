defmodule ConvergerAgent.Turn do
  @moduledoc """
  One user turn: a message frame with `"from" => "user"` of one conversation.

    * `conversation_id`, `id`, `seq` - the conversation, the activity id and
      its seq in the conversation
    * `text` - `data.text` (`""` for messages without text)
    * `message` - `%{type: type, data: data, raw: frame}`, `raw` being the
      whole frame as received
    * `participant` - the sender `%{id: id, role: role, name: name}`, or nil
    * `meta` - the per-turn context (mekik/1 meta), never stored
    * `metadata` - the stored activity metadata
    * `action` - `metadata.action`: the chip or button the user tapped
      (`%{label: label, value: value, url: url}`), or nil
    * `reply_to` - the frame's `replyTo` (`%{"id" => ..., "seq" => ...}`)
    * `timestamp` - milliseconds since the epoch
  """

  defstruct [
    :conversation_id,
    :id,
    :seq,
    :participant,
    :meta,
    :metadata,
    :action,
    :reply_to,
    :timestamp,
    text: "",
    message: %{type: nil, data: %{}, raw: %{}}
  ]

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          id: String.t() | nil,
          seq: integer(),
          text: String.t(),
          message: %{type: String.t(), data: map(), raw: map()},
          participant:
            %{id: String.t() | nil, role: String.t() | nil, name: String.t() | nil} | nil,
          meta: map() | nil,
          metadata: map() | nil,
          action: %{label: String.t() | nil, value: term(), url: String.t() | nil} | nil,
          reply_to: map() | nil,
          timestamp: integer() | nil
        }

  @doc false
  def from_frame(conversation_id, frame) do
    data = map(frame["data"]) || %{}
    metadata = map(frame["metadata"])

    %__MODULE__{
      conversation_id: conversation_id,
      id: str(frame["id"]),
      seq: frame["seq"],
      text: str(data["text"]) || "",
      message: %{type: frame["type"], data: data, raw: frame},
      participant: participant(map(frame["sender"])),
      meta: map(frame["meta"]),
      metadata: metadata,
      action: action(metadata && map(metadata["action"])),
      reply_to: map(frame["replyTo"]),
      timestamp: if(is_number(frame["timestamp"]), do: trunc(frame["timestamp"]))
    }
  end

  defp participant(nil), do: nil

  defp participant(s),
    do: %{id: str(s["id"]), role: str(s["role"]), name: str(s["name"])}

  defp action(nil), do: nil
  defp action(a), do: %{label: str(a["label"]), value: a["value"], url: str(a["url"])}

  defp map(v) when is_map(v), do: v
  defp map(_), do: nil

  defp str(v) when is_binary(v), do: v
  defp str(_), do: nil
end
