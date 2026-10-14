defmodule ConvergerAgent.Schemas do
  @moduledoc false
  # The Protocol v1 JSON Schemas (priv/protocol/v1 of the repository), every
  # frame the agent sends is validated against. Also the JSV resolver mapping
  # each schema's $id to its file, so $refs resolve offline.

  @behaviour JSV.Resolver

  @base "https://converger.aimtune.dev/schemas/protocol/v1/"

  def dir do
    System.get_env("CONVERGER_SCHEMA_DIR") ||
      Path.expand("../../../../priv/protocol/v1", __DIR__)
  end

  @doc "Every `*.schema.json` under `dir/0`, by `$id`."
  def index do
    case :persistent_term.get({__MODULE__, :index}, nil) do
      nil ->
        index =
          dir()
          |> Path.join("**/*.schema.json")
          |> Path.wildcard()
          |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
          |> Enum.filter(&is_binary(&1["$id"]))
          |> Map.new(&{&1["$id"], &1})

        :persistent_term.put({__MODULE__, :index}, index)
        index

      index ->
        index
    end
  end

  @doc "The built root of a schema, by path relative to `dir/0`."
  def root(relative) do
    key = {__MODULE__, :root, relative}

    case :persistent_term.get(key, nil) do
      nil ->
        root =
          JSV.build!(%{"$ref" => @base <> relative},
            resolver: [__MODULE__, JSV.Resolver.Embedded]
          )

        :persistent_term.put(key, root)
        root

      root ->
        root
    end
  end

  def envelope, do: root("frames/channel/client-envelope.schema.json")
  def hello, do: root("frames/client/hello.schema.json")

  @doc "`:ok` or `{:error, message}` for a frame the agent sent."
  def validate(%{"type" => "ping"}), do: :ok
  def validate(%{"type" => "hello"} = frame), do: validate(frame, hello())
  def validate(frame), do: validate(frame, envelope())

  def validate(frame, root) do
    case JSV.validate(frame, root) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error |> JSV.normalize_error() |> inspect(limit: :infinity)}
    end
  end

  @impl JSV.Resolver
  def resolve(@base <> _ = uri, _opts) do
    case Map.fetch(index(), uri) do
      {:ok, schema} -> {:normal, schema}
      :error -> {:error, {:unknown_protocol_schema, uri}}
    end
  end

  def resolve(uri, _opts), do: {:error, {:unknown_schema, uri}}
end
