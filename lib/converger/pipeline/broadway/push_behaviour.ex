defmodule Converger.Pipeline.Broadway.PushBehaviour do
  @moduledoc """
  Behaviour for Broadway message push modules.

  Implement this behaviour for custom message brokers.
  """

  @callback push(message :: map(), config :: keyword()) :: :ok | {:error, term()}
end
