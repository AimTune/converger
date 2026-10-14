defmodule ConvergerAgent.Ack do
  @moduledoc """
  The `ack` of a stored message send (`ConvergerAgent.Reply.text/3`,
  `ConvergerAgent.Reply.message/3`): the activity `id` and its `seq` in the
  conversation. `duplicate` is true when the server had already stored a send
  with this `clientId` (a re-send after a reconnect).
  """

  defstruct [:client_id, :id, :seq, :timestamp, duplicate: false]

  @type t :: %__MODULE__{
          client_id: String.t() | nil,
          id: String.t() | nil,
          seq: integer() | nil,
          timestamp: integer() | nil,
          duplicate: boolean()
        }

  @doc false
  def from_frame(frame) do
    %__MODULE__{
      client_id: str(frame["clientId"]),
      id: str(frame["id"]),
      seq: int(frame["seq"]),
      timestamp: int(frame["timestamp"]),
      duplicate: frame["duplicate"] == true
    }
  end

  defp str(v) when is_binary(v), do: v
  defp str(_), do: nil

  defp int(v) when is_integer(v), do: v
  defp int(_), do: nil
end
