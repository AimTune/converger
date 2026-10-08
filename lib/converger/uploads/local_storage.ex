defmodule Converger.Uploads.LocalStorage do
  @moduledoc """
  Local disk storage backend, intended for development and single-node
  setups.

  Files are written below `:dir` (default `"priv/uploads"`), which is **not**
  served by `Plug.Static`. Downloads go through the authenticated
  `GET /api/v1/converger/attachments/:id` endpoint.

  Options:

    * `:dir` - base directory (relative paths are resolved against the
      current working directory)
  """

  @behaviour Converger.Uploads.Storage

  @default_dir "priv/uploads"

  @impl true
  def put(config, key, binary, _opts \\ []) do
    with {:ok, path} <- path_for(config, key),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, binary)
    end
  end

  @impl true
  def get(config, key) do
    with {:ok, path} <- path_for(config, key) do
      case File.read(path) do
        {:ok, binary} -> {:ok, binary}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def delete(config, key) do
    with {:ok, path} <- path_for(config, key) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def signed_get_url(_config, _key, _opts), do: {:error, :unsupported}

  @impl true
  def presigned_put_url(_config, _key, _opts), do: {:error, :unsupported}

  @impl true
  def local_path(config, key) do
    with {:ok, path} <- path_for(config, key) do
      if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}
    end
  end

  @doc "The absolute base directory for the given config."
  def base_dir(config), do: config |> Keyword.get(:dir, @default_dir) |> Path.expand()

  # Keys are generated internally, but refuse anything that would escape
  # the base directory anyway.
  defp path_for(config, key) do
    base = base_dir(config)
    path = Path.expand(key, base)

    if String.starts_with?(path, base <> "/") and not String.contains?(key, "..") do
      {:ok, path}
    else
      {:error, :invalid_key}
    end
  end
end
