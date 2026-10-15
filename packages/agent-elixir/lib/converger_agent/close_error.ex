defmodule ConvergerAgent.CloseError do
  @moduledoc """
  Passed to the error callback when the server closes the connection with a
  code that reconnecting cannot help (1008, 4400, a second consecutive 4401,
  4403). The connection process then stops with
  `{:shutdown, {:closed, code, last_error}}`.

  `last_error` is the last connection-level `error` frame received before the
  close (a `ConvergerAgent.Error`), if any.
  """

  defexception [:code, :reason, :last_error]

  @type t :: %__MODULE__{
          code: integer(),
          reason: String.t(),
          last_error: ConvergerAgent.Error.t() | nil
        }

  @impl true
  def message(%__MODULE__{last_error: %ConvergerAgent.Error{} = last} = e),
    do: "converger: connection closed (#{e.code}): #{Map.get(last, :message)}"

  def message(%__MODULE__{} = e), do: "converger: connection closed (#{e.code}) #{e.reason}"
end
