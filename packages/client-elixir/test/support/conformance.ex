defmodule ConvergerClient.Conformance do
  @moduledoc false
  # Loads the shared conformance suite (packages/conformance).

  def dir do
    System.get_env("CONVERGER_CONFORMANCE_DIR") ||
      Path.expand("../../../conformance", __DIR__)
  end

  def load(name), do: dir() |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp norm(name), do: name |> to_string() |> String.replace("_", "") |> String.downcase()

  @doc "Follows a conformance result path through structs, maps and lists."
  def resolve(value, path) do
    path
    |> String.split(".")
    |> Enum.reduce(value, fn seg, acc ->
      cond do
        is_list(acc) ->
          Enum.at(acc, String.to_integer(seg))

        is_struct(acc) ->
          key = acc |> Map.from_struct() |> Map.keys() |> Enum.find(&(norm(&1) == norm(seg)))
          key || raise "no field #{seg} in #{inspect(acc.__struct__)}"
          Map.fetch!(acc, key)

        is_map(acc) ->
          key = acc |> Map.keys() |> Enum.find(&(norm(&1) == norm(seg)))
          key || raise "no key #{seg} in #{inspect(Map.keys(acc))}"
          Map.fetch!(acc, key)
      end
    end)
  end
end
