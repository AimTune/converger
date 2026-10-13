defmodule Converger.ProtocolSchemas do
  @moduledoc """
  Loads the Converger Protocol v1 JSON Schemas (`priv/protocol/v1`).

  Used at runtime to validate typed message payloads on write
  (`Converger.Activities.MessagePayload`, #68) and by the conformance suite in
  `test/protocol/`.

  Every schema's `$id` lives under `base_uri/0`; this module is also the
  `JSV.Resolver` that maps those ids back to files, so `$ref`s between the
  schema files resolve offline.
  """

  @behaviour JSV.Resolver

  @base_uri "https://converger.aimtune.dev/schemas/protocol/v1/"

  def base_uri, do: @base_uri

  @doc "The schema directory (`priv/protocol/v1` of the application)."
  def dir, do: Application.app_dir(:converger, "priv/protocol/v1")

  @doc "Paths of every `*.schema.json`, relative to `dir/0`."
  def schema_paths do
    dir = dir()

    dir
    |> Path.join("**/*.schema.json")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  @doc "Decoded JSON of a file under `dir/0`."
  # Paths are the schemas' own `$ref`s and fixed names (`schema_path!/1`
  # keeps them inside `dir/0`), never raw client input.
  # sobelow_skip ["Traversal.FileModule"]
  def read!(relative_path) do
    relative_path |> schema_path!() |> File.read!() |> Jason.decode!()
  end

  defp schema_path!(relative_path) do
    case Path.safe_relative(relative_path) do
      {:ok, safe} -> Path.join(dir(), safe)
      :error -> raise ArgumentError, "not a protocol schema path: #{inspect(relative_path)}"
    end
  end

  @doc "Build a validation root for the schema at `relative_path`."
  def build!(relative_path) do
    relative_path
    |> read!()
    |> JSV.build!(resolver: [__MODULE__, JSV.Resolver.Embedded])
  end

  @doc """
  The built root for `relative_path`, built once per node and kept in
  `:persistent_term` (the schemas are part of the release and never change
  at runtime).
  """
  def root!(relative_path) do
    key = {__MODULE__, relative_path}

    case :persistent_term.get(key, nil) do
      nil ->
        root = build!(relative_path)
        :persistent_term.put(key, root)
        root

      root ->
        root
    end
  end

  @doc "`:ok` or `{:error, message}` for `data` against a built root."
  def validate(data, root) do
    case JSV.validate(data, root) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error |> JSV.normalize_error() |> inspect(limit: :infinity)}
    end
  end

  @doc """
  `:ok` or `{:error, details}` for `data` against a built root, where
  `details` maps each failing JSON pointer (`"#/data/buttons/0/label"`) to its
  messages, the shape of `error.details`.
  """
  def validate_details(data, root) do
    case JSV.validate(data, root) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error |> JSV.normalize_error() |> details()}
    end
  end

  # Errors of applicators ("property 'data' did not conform ...") only point
  # at nested units; the leaves (required, type, maxLength, ...) say what is
  # wrong.
  @applicator_kinds [:properties, :items, :prefixItems, :allOf, :anyOf, :oneOf, :not, :"$ref"] ++
                      [:then, :else, :if, :"if/then", :"if/else", :additionalProperties] ++
                      [:patternProperties, :contains, :dependentSchemas, :unevaluatedProperties]

  defp details(normalized) do
    case normalized |> leaf_errors() |> Enum.uniq() do
      [] ->
        %{"#" => ["is invalid"]}

      errors ->
        errors
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {location, messages} -> {location, Enum.uniq(messages)} end)
    end
  end

  defp leaf_errors(%{instanceLocation: location, errors: errors} = unit) when is_list(errors) do
    own =
      for %{kind: kind, message: message} <- errors,
          kind not in @applicator_kinds,
          is_binary(message),
          do: {location, message}

    own ++ (unit |> Map.drop([:errors]) |> Map.values() |> leaf_errors()) ++ leaf_errors(errors)
  end

  defp leaf_errors(%{} = map), do: map |> Map.values() |> leaf_errors()
  defp leaf_errors(list) when is_list(list), do: Enum.flat_map(list, &leaf_errors/1)
  defp leaf_errors(_value), do: []

  # Resolves only `$ref`s under `base_uri/0`, kept inside `dir/0` by
  # Path.safe_relative/1.
  # sobelow_skip ["Traversal.FileModule"]
  @impl JSV.Resolver
  def resolve(@base_uri <> relative_path, _opts) do
    with {:ok, safe} <- Path.safe_relative(relative_path),
         {:ok, json} <- File.read(Path.join(dir(), safe)) do
      {:normal, Jason.decode!(json)}
    else
      :error -> {:error, {:protocol_schema_not_found, relative_path, :unsafe_path}}
      {:error, reason} -> {:error, {:protocol_schema_not_found, relative_path, reason}}
    end
  end

  def resolve(uri, _opts), do: {:error, {:unknown_schema, uri}}
end
