defmodule ConvergerAgent.TestBot do
  @moduledoc false
  # A `use ConvergerAgent` module for the child_spec test.

  use ConvergerAgent

  @impl true
  def handle_turn(turn, reply), do: ConvergerAgent.Reply.text(reply, "bot: " <> turn.text)

  @impl true
  def handle_error(_error), do: :ok
end
