defmodule ConvergerAgent.Error do
  @moduledoc """
  An `error` frame of Protocol v1 (docs/protocol/v1.md section 12): a refused
  send (returned by `ConvergerAgent.Reply.text/3` and
  `ConvergerAgent.Reply.message/3`), an error about one conversation, or a
  connection-level error (both passed to the error callback).

  `code` `"unknown_interrupt"` is raised by the SDK itself when a `resume`
  answers an interrupt this agent is not waiting for.
  """

  defexception [
    :code,
    :message,
    :number,
    :client_id,
    :frame_type,
    :details,
    :conversation_id,
    :retry_after_ms,
    retryable: false
  ]

  @type t :: %__MODULE__{
          code: String.t() | nil,
          message: String.t() | nil,
          number: integer() | nil,
          retryable: boolean(),
          retry_after_ms: integer() | nil,
          client_id: String.t() | nil,
          frame_type: String.t() | nil,
          details: map() | nil,
          conversation_id: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{conversation_id: nil} = e),
    do: "converger: #{e.code}: #{Map.get(e, :message)}"

  def message(%__MODULE__{} = e),
    do: "converger: #{e.code} (conversation #{e.conversation_id}): #{Map.get(e, :message)}"

  @doc false
  def from_frame(conversation_id, frame) do
    data = if is_map(frame["data"]), do: frame["data"], else: %{}

    %__MODULE__{
      code: str(data["code"]),
      message: str(data["message"]),
      number: int(data["number"]),
      retryable: data["retryable"] == true,
      retry_after_ms: int(data["retryAfterMs"]),
      client_id: str(data["clientId"]),
      frame_type: str(data["frameType"]),
      details: if(is_map(data["details"]), do: data["details"]),
      conversation_id: conversation_id
    }
  end

  defp str(v) when is_binary(v), do: v
  defp str(_), do: nil

  defp int(v) when is_integer(v), do: v
  defp int(_), do: nil
end
