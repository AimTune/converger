defmodule Converger.Uploads do
  @moduledoc """
  Context module for file uploads.
  """

  @max_file_size 10 * 1024 * 1024

  def store_file(%Plug.Upload{} = upload, opts \\ []) do
    with :ok <- validate_file_size(upload.path),
         {:ok, binary} <- File.read(upload.path) do
      storage().store(upload.filename, binary, opts)
    end
  end

  def store_binary(filename, binary, opts \\ []) when is_binary(binary) do
    if byte_size(binary) > @max_file_size do
      {:error, "File too large (max #{div(@max_file_size, 1024 * 1024)}MB)"}
    else
      storage().store(filename, binary, opts)
    end
  end

  def url(path), do: storage().url(path)

  def delete(path), do: storage().delete(path)

  def max_file_size, do: @max_file_size

  defp validate_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_file_size -> :ok
      {:ok, _} -> {:error, "File too large (max #{div(@max_file_size, 1024 * 1024)}MB)"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp storage do
    Application.get_env(:converger, :upload_storage, Converger.Uploads.LocalStorage)
  end
end
