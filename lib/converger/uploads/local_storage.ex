defmodule Converger.Uploads.LocalStorage do
  @moduledoc """
  Local disk storage backend for file uploads.
  """

  @behaviour Converger.Uploads.Storage

  @impl true
  def store(filename, binary, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    upload_dir = upload_directory(tenant_id)
    File.mkdir_p!(upload_dir)

    safe_filename = sanitize_filename(filename)
    unique_name = "#{Ecto.UUID.generate()}_#{safe_filename}"
    file_path = Path.join(upload_dir, unique_name)

    case File.write(file_path, binary) do
      :ok ->
        relative_path = Path.join(["uploads", tenant_id, unique_name])
        {:ok, %{path: relative_path, url: "/#{relative_path}", size: byte_size(binary)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def url(path) do
    "/#{path}"
  end

  @impl true
  def delete(path) do
    full_path = Path.join(base_directory(), path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_directory(tenant_id) do
    Path.join([base_directory(), "uploads", tenant_id])
  end

  defp base_directory do
    Application.get_env(:converger, :upload_dir, "priv/static")
  end

  defp sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^\w\-\.]/, "_")
    |> String.slice(0, 100)
  end
end
