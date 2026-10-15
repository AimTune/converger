defmodule ConvergerAgent.FixtureHandler do
  @moduledoc false
  # The turn handler of the conformance fixture: runs the ops of
  # handlers[turn.text] (or handlers["*"]).

  alias ConvergerAgent.Reply

  def new(handlers) do
    fn turn, reply ->
      ops = Map.get(handlers, turn.text) || Map.fetch!(handlers, "*")

      Enum.reduce_while(ops, "", fn op, answer ->
        fill = fn s ->
          s |> String.replace("{text}", turn.text) |> String.replace("{answer}", answer)
        end

        case run(op, reply, fill) do
          :ok -> {:cont, answer}
          {:ok, %ConvergerAgent.Ack{}} -> {:cont, answer}
          {:ok, new_answer} when is_binary(new_answer) -> {:cont, new_answer}
          {:ok, new_answer} -> {:cont, Jason.encode!(new_answer)}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp run(%{"op" => "text"} = op, reply, fill),
    do: Reply.text(reply, fill.(op["text"]), actions: op["actions"])

  defp run(%{"op" => "ask"} = op, reply, _fill),
    do: Reply.ask(reply, op["payload"], actions: op["actions"])

  defp run(%{"op" => "typing"} = op, reply, _fill), do: Reply.typing(reply, op["on"])

  defp run(%{"op" => "toolCall"} = op, reply, _fill) do
    Reply.tool_call(reply, %{
      id: op["id"],
      name: op["name"],
      status: op["status"],
      params: op["params"],
      result: op["result"]
    })
  end

  defp run(%{"op" => "message"} = op, reply, _fill),
    do: Reply.message(reply, op["type"], op["data"])

  defp run(op, _reply, _fill), do: {:error, {:unknown_op, op["op"]}}
end
