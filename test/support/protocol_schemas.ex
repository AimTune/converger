defmodule Converger.ProtocolSchemas do
  @moduledoc """
  Loads the Converger Protocol v1 JSON Schemas (`priv/protocol/v1`) for the
  conformance suite in `test/protocol/`.

  Every schema's `$id` lives under `base_uri/0`; this module is also the
  `JSV.Resolver` that maps those ids back to files, so `$ref`s between the
  schema files resolve offline.
  """

  @behaviour JSV.Resolver

  @base_uri "https://converger.aimtune.dev/schemas/protocol/v1/"
  @dir Path.expand("../../priv/protocol/v1", __DIR__)

  def base_uri, do: @base_uri
  def dir, do: @dir

  @doc "Paths of every `*.schema.json`, relative to `dir/0`."
  def schema_paths do
    @dir
    |> Path.join("**/*.schema.json")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @dir))
    |> Enum.sort()
  end

  @doc "Decoded JSON of a file under `dir/0`."
  def read!(relative_path) do
    @dir |> Path.join(relative_path) |> File.read!() |> Jason.decode!()
  end

  @doc "Build a validation root for the schema at `relative_path`."
  def build!(relative_path) do
    relative_path
    |> read!()
    |> JSV.build!(resolver: [__MODULE__, JSV.Resolver.Embedded])
  end

  @doc "`:ok` or `{:error, message}` for `data` against a built root."
  def validate(data, root) do
    case JSV.validate(data, root) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error |> JSV.normalize_error() |> inspect(limit: :infinity)}
    end
  end

  @impl JSV.Resolver
  def resolve(@base_uri <> relative_path, _opts) do
    path = Path.join(@dir, relative_path)

    case File.read(path) do
      {:ok, json} -> {:normal, Jason.decode!(json)}
      {:error, reason} -> {:error, {:protocol_schema_not_found, relative_path, reason}}
    end
  end

  def resolve(uri, _opts), do: {:error, {:unknown_schema, uri}}
end
