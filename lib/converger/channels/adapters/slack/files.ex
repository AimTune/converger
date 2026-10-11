defmodule Converger.Channels.Adapters.Slack.Files do
  @moduledoc """
  File attachments of the `slack` channel adapter.

  ## Outbound

  Slack's `files.uploadV2` flow, in three steps:

    1. `prepare/2` - for every file attachment, fetch the bytes,
       `files.getUploadURLExternal` and upload them. Nothing is visible in
       Slack yet, so a failure here is retried without leaving a trace.
    2. the adapter posts the message text (`chat.postMessage`);
    3. `share/4` - `files.completeUploadExternal` shares the uploaded files
       in the same channel and thread.

  A file attachment is one with a `contentUrl`: a Converger upload
  (`/api/v1/converger/attachments/<id>`, read from storage) or an `http(s)`
  URL, fetched through `Converger.Channels.UrlGuard` (private and link-local
  targets are refused). Files larger than
  `Converger.Uploads.max_file_size/0` are refused permanently.

  ## Inbound

  With `download_files: true` in the channel config, `rehost/2` downloads
  each Slack file with the bot token (`files.info` first when Slack only sent
  a stub, `file_access: "check_file_info"`) and stores it as a Converger
  upload, so the attachment gets a `contentUrl` clients can fetch. A file
  that cannot be downloaded keeps its Slack reference in `channelData`.
  """

  alias Converger.Channels.Adapters.Slack.{Api, Blocks}

  alias Converger.Channels.{DeliveryError, UrlGuard}
  alias Converger.Uploads

  require Logger

  @upload_path ~r"/api/v1/converger/attachments/([0-9a-fA-F-]{36})(?:[/?#]|\z)"

  @doc "The attachments of an activity that are files to upload."
  def file_attachments(attachments) do
    for attachment <- List.wrap(attachments),
        is_map(attachment),
        not Blocks.card?(attachment),
        is_binary(attachment["contentUrl"]) and attachment["contentUrl"] != "",
        do: attachment
  end

  @doc """
  Fetch and upload every file attachment (steps 1 and 2 of the flow).
  Returns `{:ok, [%{"id" => file_id, "title" => name}]}` or
  `{:error, %DeliveryError{}}`.
  """
  def prepare(channel, activity) do
    activity.attachments
    |> file_attachments()
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {attachment, index}, {:ok, acc} ->
      case prepare_one(channel, activity, attachment, index) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp prepare_one(channel, activity, attachment, index) do
    name = attachment["name"] || "file-#{index}"

    with {:ok, data} <- fetch(activity, attachment),
         {:ok, %{"upload_url" => url, "file_id" => file_id}} <-
           Api.call(
             channel,
             "files.getUploadURLExternal",
             [filename: name, length: byte_size(data)],
             form: true
           ),
         :ok <- Api.upload_bytes(channel, url, data) do
      {:ok, %{"id" => file_id, "title" => name}}
    end
  end

  @doc """
  Share prepared files in `slack_channel` (and `thread_ts`), step 3 of the
  flow. Returns `{:ok, response}` or `{:error, %DeliveryError{}}`.
  """
  def share(_channel, [], _slack_channel, _thread_ts), do: {:ok, %{}}

  def share(channel, files, slack_channel, thread_ts) do
    body =
      [files: Jason.encode!(files), channel_id: slack_channel]
      |> then(fn body -> if thread_ts, do: body ++ [thread_ts: thread_ts], else: body end)

    Api.call(channel, "files.completeUploadExternal", body, form: true)
  end

  ## Fetching outbound files

  defp fetch(activity, %{"contentUrl" => url}) do
    case Regex.run(@upload_path, url) do
      [_, id] -> fetch_upload(activity.tenant_id, id)
      nil -> fetch_url(url)
    end
  end

  defp fetch_upload(tenant_id, id) do
    case Uploads.get_attachment(tenant_id, id) do
      nil ->
        {:error, DeliveryError.permanent("attachment #{id} not found")}

      attachment ->
        case Uploads.download(attachment) do
          {:data, data} ->
            {:ok, data}

          # A storage URL Converger signed itself: no SSRF check needed.
          {:redirect, url} ->
            get(url, nil)

          {:file, path} ->
            read_file(path)

          {:error, reason} ->
            {:error, %DeliveryError{reason: "attachment #{id}: #{inspect(reason)}"}}
        end
    end
  end

  # The path comes from the storage backend (LocalStorage), not from input.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, %DeliveryError{reason: "attachment file: #{inspect(reason)}"}}
    end
  end

  defp fetch_url(url) do
    case UrlGuard.resolve(url) do
      {:ok, target} ->
        get(pinned_url(target), target)

      {:error, {:unresolvable, _} = reason} ->
        {:error,
         %DeliveryError{reason: "attachment URL rejected: #{UrlGuard.format_error(reason)}"}}

      {:error, reason} ->
        {:error,
         DeliveryError.permanent("attachment URL rejected: #{UrlGuard.format_error(reason)}")}
    end
  end

  defp get(url, target) do
    max_bytes = Uploads.max_file_size()

    options =
      [
        method: :get,
        url: url,
        redirect: false,
        retry: false,
        decode_body: false,
        receive_timeout: 30_000
      ]
      |> Keyword.merge(connect_options(target))
      |> Keyword.merge(Application.get_env(:converger, :slack_req_options, []))

    case Converger.HTTP.request(options) do
      {:ok, %Req.Response{status: 200, body: body}} when byte_size(body) <= max_bytes ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, DeliveryError.permanent("attachment larger than #{max_bytes} bytes")}

      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:error, DeliveryError.from_http(status, headers, body, "attachment download")}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, "attachment download")}
    end
  end

  # Pin the request to the address that passed the SSRF check, keeping the
  # host name for TLS (as Converger.Channels.Adapters.Webhook does).
  defp pinned_url(%{uri: uri, ip: nil}), do: URI.to_string(uri)

  defp pinned_url(%{uri: uri, ip: ip}),
    do: URI.to_string(%{uri | host: ip |> :inet.ntoa() |> to_string()})

  defp connect_options(%{ip: ip, host: host}) when is_tuple(ip),
    do:
      [connect_options: [hostname: host]] ++ if(tuple_size(ip) == 8, do: [inet6: true], else: [])

  defp connect_options(_target), do: []

  ## Inbound

  @doc """
  Store the Slack files among `attachments` as Converger uploads (see the
  moduledoc). Other attachments, and files that fail, are returned as is.
  """
  def rehost(channel, attachments) do
    Enum.map(attachments, fn
      %{"channelData" => %{"provider" => "slack", "fileId" => file_id}} = attachment ->
        case rehost_one(channel, attachment, file_id) do
          {:ok, rehosted} ->
            rehosted

          {:error, reason} ->
            Logger.warning("Slack file #{file_id} not downloaded, keeping its reference",
              channel_id: Map.get(channel, :id),
              reason: inspect(reason)
            )

            attachment
        end

      attachment ->
        attachment
    end)
  end

  defp rehost_one(channel, attachment, file_id) do
    with {:ok, url, name} <- download_url(channel, attachment, file_id),
         {:ok, data} <- Api.download(channel, url, max_bytes: Uploads.max_file_size()),
         {:ok, upload} <- Uploads.create_attachment(channel.tenant_id, {name, data}) do
      {:ok,
       attachment
       |> Map.merge(%{
         "contentType" => upload.content_type,
         "contentUrl" => "/api/v1/converger/attachments/#{upload.id}",
         "size" => upload.size
       })}
    end
  end

  defp download_url(channel, attachment, file_id) do
    case get_in(attachment, ["channelData", "urlPrivateDownload"]) do
      url when is_binary(url) ->
        {:ok, url, attachment["name"] || file_id}

      _ ->
        case Api.call(channel, "files.info", [file: file_id], form: true, timeout: 5_000) do
          {:ok, %{"file" => %{"url_private_download" => url} = file}} when is_binary(url) ->
            {:ok, url, file["name"] || file_id}

          {:ok, _} ->
            {:error, :no_download_url}

          {:error, _} = error ->
            error
        end
    end
  end
end
