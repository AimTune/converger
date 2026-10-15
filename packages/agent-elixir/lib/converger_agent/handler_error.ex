defmodule ConvergerAgent.HandlerError do
  @moduledoc """
  Passed to the error callback when a turn handler returned `{:error, reason}`
  (`kind` `:error_tuple`), raised (`:error`), threw (`:throw`) or exited
  (`:exit`). The run of that turn ended with status `"error"`.
  """

  defexception [:conversation_id, :turn_id, :kind, :reason, :stacktrace]

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          turn_id: String.t() | nil,
          kind: :error_tuple | :error | :throw | :exit,
          reason: term(),
          stacktrace: Exception.stacktrace() | nil
        }

  @impl true
  def message(%__MODULE__{kind: :error, reason: reason} = e) when is_exception(reason),
    do:
      "converger: turn handler failed (conversation #{e.conversation_id}): " <>
        Exception.message(reason)

  def message(%__MODULE__{} = e),
    do:
      "converger: turn handler failed (conversation #{e.conversation_id}): #{inspect(e.kind)} #{inspect(e.reason)}"
end
