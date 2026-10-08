defmodule Converger.Uploads do
  @moduledoc """
  Context for file uploads and the `attachments` table.

  Configuration (see `docs/storage.md`):

      config :converger, Converger.Uploads,
        storage: Converger.Uploads.LocalStorage,
        storage_opts: [dir: "priv/uploads"],
        max_file_size: 10 * 1024 * 1024,
        allowed_content_types: [...],
        signed_url_ttl: 300,
        cdn: nil

  Uploads are validated by size, their MIME type is sniffed from the bytes
  (the client supplied type is ignored) and checked against the tenant's
  allowlist (`tenants.allowed_upload_types`, falling back to the global
  `:allowed_content_types`).
  """

  import Ecto.Query, warn: false

  alias Converger.Repo
  alias Converger.Tenants.Tenant
  alias Converger.Uploads.{Attachment, CDN, MimeSniffer}

  @default_max_file_size 10 * 1024 * 1024
  @default_signed_url_ttl 300

  @default_allowed_content_types ~w(
    image/png image/jpeg image/gif image/webp
    application/pdf
    video/mp4 video/webm video/quicktime
    audio/mpeg audio/ogg audio/mp4 audio/aac audio/wav
    text/plain
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.openxmlformats-officedocument.presentationml.presentation
  )

  ## Configuration

  def config, do: Application.get_env(:converger, __MODULE__, [])

  def storage, do: Keyword.get(config(), :storage, Converger.Uploads.LocalStorage)

  def storage_opts, do: Keyword.get(config(), :storage_opts, [])

  def max_file_size, do: Keyword.get(config(), :max_file_size) || @default_max_file_size

  def signed_url_ttl, do: Keyword.get(config(), :signed_url_ttl) || @default_signed_url_ttl

  def default_allowed_content_types,
    do: Keyword.get(config(), :allowed_content_types) || @default_allowed_content_types

  @doc "The MIME allowlist for a tenant (struct or id)."
  def allowed_content_types(%Tenant{allowed_upload_types: types})
      when is_list(types) and types != [],
      do: types

  def allowed_content_types(%Tenant{}), do: default_allowed_content_types()

  def allowed_content_types(tenant_id) when is_binary(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      nil -> default_allowed_content_types()
      tenant -> allowed_content_types(tenant)
    end
  end

  ## Creating attachments

  @doc """
  Validates and stores an uploaded file and records an `Attachment`.

  Options: `:conversation_id`, `:filename` (overrides the upload's name).

  Errors: `{:error, :too_large}`, `{:error, {:unsupported_type, type}}`,
  `{:error, %Ecto.Changeset{}}` or a storage error.
  """
  def create_attachment(tenant_id, upload, opts \\ [])

  # `upload.path` is the temp file Plug created for the multipart part, not a
  # client-supplied path.
  # sobelow_skip ["Traversal.FileModule"]
  def create_attachment(tenant_id, %Plug.Upload{} = upload, opts) do
    with :ok <- check_file_size(upload.path),
         {:ok, binary} <- File.read(upload.path) do
      create_attachment(
        tenant_id,
        {Keyword.get(opts, :filename, upload.filename), binary},
        opts
      )
    end
  end

  def create_attachment(tenant_id, {filename, binary}, opts) when is_binary(binary) do
    with :ok <- check_size(byte_size(binary)),
         content_type = MimeSniffer.sniff(binary),
         :ok <- check_content_type(tenant_id, content_type) do
      id = Ecto.UUID.generate()
      key = "#{tenant_id}/#{id}"

      attrs = %{
        storage_key: key,
        content_type: content_type,
        size: byte_size(binary),
        sha256: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower),
        filename: sanitize_filename(filename)
      }

      changeset =
        Attachment.changeset(
          %Attachment{
            id: id,
            tenant_id: tenant_id,
            conversation_id: Keyword.get(opts, :conversation_id)
          },
          attrs
        )

      with {:ok, changeset} <- validate(changeset),
           :ok <- storage().put(storage_opts(), key, binary, content_type: content_type) do
        case Repo.insert(changeset) do
          {:ok, attachment} ->
            {:ok, attachment}

          {:error, changeset} ->
            _ = storage().delete(storage_opts(), key)
            {:error, changeset}
        end
      end
    end
  end

  defp validate(%Ecto.Changeset{valid?: true} = cs), do: {:ok, cs}
  defp validate(cs), do: {:error, cs}

  @doc "Associates an attachment with the activity that references it."
  def link_activity(%Attachment{} = attachment, activity_id) do
    attachment
    |> Ecto.Changeset.change(activity_id: activity_id)
    |> Repo.update()
  end

  ## Reading attachments

  @doc "Gets an attachment scoped to a tenant. Returns `nil` if missing or foreign."
  def get_attachment(tenant_id, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, _} <- Ecto.UUID.cast(tenant_id) do
      Repo.one(from a in Attachment, where: a.id == ^uuid and a.tenant_id == ^tenant_id)
    else
      _ -> nil
    end
  end

  def list_attachments(tenant_id) do
    Repo.all(
      from a in Attachment, where: a.tenant_id == ^tenant_id, order_by: [desc: a.inserted_at]
    )
  end

  @doc """
  Resolves how an attachment should be delivered to a client:

    * `{:redirect, url}` - CDN or signed storage URL (cloud backends)
    * `{:file, path}` - local file to send
    * `{:data, binary}` - bytes fetched from storage (backend without
      signed URLs or local paths)
  """
  def download(%Attachment{} = attachment) do
    backend = storage()
    opts = storage_opts()
    ttl = signed_url_ttl()

    signed_opts = [
      expires_in: ttl,
      content_type: attachment.content_type,
      content_disposition: content_disposition(attachment)
    ]

    origin_query = fn ->
      case backend.signed_get_url(opts, attachment.storage_key, signed_opts) do
        {:ok, url} -> URI.parse(url).query
        _ -> nil
      end
    end

    case CDN.url(Keyword.get(config(), :cdn), attachment.storage_key, ttl, origin_query) do
      {:ok, url} ->
        {:redirect, url}

      :none ->
        case backend.signed_get_url(opts, attachment.storage_key, signed_opts) do
          {:ok, url} -> {:redirect, url}
          {:error, :unsupported} -> fetch_local_or_data(backend, opts, attachment.storage_key)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp fetch_local_or_data(backend, opts, key) do
    local =
      if Code.ensure_loaded?(backend) and function_exported?(backend, :local_path, 2),
        do: backend.local_path(opts, key),
        else: {:error, :unsupported}

    case local do
      {:ok, path} ->
        {:file, path}

      {:error, :unsupported} ->
        case backend.get(opts, key) do
          {:ok, data} -> {:data, data}
          error -> error
        end

      error ->
        error
    end
  end

  @doc "A presigned PUT for direct-to-storage uploads (where the backend supports it)."
  def presigned_put_url(key, opts \\ []) do
    storage().presigned_put_url(storage_opts(), key, Keyword.put_new(opts, :expires_in, 900))
  end

  ## Deleting

  def delete_attachment(%Attachment{} = attachment) do
    with :ok <- storage().delete(storage_opts(), attachment.storage_key) do
      Repo.delete(attachment)
    end
  end

  ## Helpers

  @inline_prefixes ~w(image/ video/ audio/)

  @doc "`Content-Disposition` value for an attachment."
  def content_disposition(%Attachment{content_type: ct, filename: filename}) do
    disposition =
      if ct == "application/pdf" or String.starts_with?(ct, @inline_prefixes),
        do: "inline",
        else: "attachment"

    case filename do
      nil ->
        disposition

      name ->
        ascii =
          String.replace(name, ~r/[^\w\-\. ]/u, "_") |> String.replace(~r/[^\x20-\x7E]/, "_")

        "#{disposition}; filename=\"#{ascii}\"; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)}"
    end
  end

  defp check_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> check_size(size)
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_size(size) do
    if size <= max_file_size(), do: :ok, else: {:error, :too_large}
  end

  defp check_content_type(tenant_id, content_type) do
    if content_type in allowed_content_types(tenant_id),
      do: :ok,
      else: {:error, {:unsupported_type, content_type}}
  end

  defp sanitize_filename(nil), do: nil

  defp sanitize_filename(filename) do
    filename
    |> to_string()
    |> String.replace("\\", "/")
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1F\x7F"]/, "")
    |> String.slice(0, 255)
    |> case do
      "" -> nil
      name -> name
    end
  end
end
