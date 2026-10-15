defmodule ConvergerClient.Model do
  @moduledoc """
  Defines response structs from a field list.

      use ConvergerClient.Model,
        fields: [conversation_id: "conversationId", token: "token", from: {"from", ConvergerClient.ChannelAccount}]

  Each field maps a struct key to a wire key, optionally with a nested model
  (applied to a map, or to every element of a list). Unknown wire keys are
  kept in `:extra`, so fields the server adds later are not lost.

  The models are hand-written today. Once the OpenAPI document of #45 ships
  at `priv/static/openapi.json`, they are checked against it (see the README).
  """

  defmacro __using__(opts) do
    fields = Keyword.fetch!(opts, :fields)

    quote bind_quoted: [fields: fields] do
      @fields fields
      defstruct Keyword.keys(fields) ++ [extra: %{}]

      @doc "Builds the struct from a decoded JSON map."
      def from_map(nil), do: nil

      def from_map(map) when is_map(map),
        do: ConvergerClient.Model.build(__MODULE__, @fields, map)

      @doc false
      def __fields__, do: @fields
    end
  end

  @doc false
  def build(module, fields, map) do
    known =
      for {key, spec} <- fields, into: %{} do
        {wire, nested} =
          case spec do
            {wire, nested} -> {wire, nested}
            wire -> {wire, nil}
          end

        {key, convert(Map.get(map, wire), nested)}
      end

    wire_keys =
      Enum.map(fields, fn {_, spec} -> if is_tuple(spec), do: elem(spec, 0), else: spec end)

    struct(module, Map.put(known, :extra, Map.drop(map, wire_keys)))
  end

  defp convert(nil, _), do: nil
  defp convert(value, nil), do: value
  defp convert(list, nested) when is_list(list), do: Enum.map(list, &nested.from_map/1)
  defp convert(map, nested) when is_map(map), do: nested.from_map(map)
  defp convert(value, _), do: value
end
