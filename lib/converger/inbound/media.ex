defmodule Converger.Inbound.Media do
  @moduledoc """
  Stores the media of an inbound message in Converger before its activity is
  created, so the activity carries a real `contentUrl`
  (`/api/v1/converger/attachments/:id`) instead of a provider media id that
  only the provider can resolve and that expires (WhatsApp media URLs live
  for minutes).

  For each attachment stub (no `contentUrl`) the channel's adapter downloads
  the file (`c:Converger.Channels.Adapter.fetch_media/2`), and
  `Converger.Uploads.create_attachment/3` stores it with the same checks as
  a client upload: size limit, sniffed MIME type, tenant allowlist.

  A failed download never loses the message: the stub is kept as parsed and
  gets `channelData.downloadError`. Set the channel config key
  `download_media` to `false` to keep stubs without downloading. See
  ADR-0039.
  """

  require Logger

  alias Converger.Channels.Adapter
  alias Converger.Uploads
  alias Converger.Uploads.Attachment

  @doc """
  Downloads and stores the media of `message`. Returns the message with its
  attachments rewritten, and the stored `Attachment`s, to be linked to the
  activity once it exists (`link/2`) or deleted when it is not created
  (`discard/1`).
  """
  @spec store(map(), map(), map()) :: {map(), [Attachment.t()]}
  def store(channel, conversation, %{"attachments" => [_ | _] = attachments} = message) do
    if download?(channel) do
      {attachments, stored} =
        attachments
        |> Enum.map(&store_one(channel, conversation, &1))
        |> Enum.unzip()

      {Map.put(message, "attachments", attachments), Enum.reject(stored, &is_nil/1)}
    else
      {message, []}
    end
  end

  def store(_channel, _conversation, message), do: {message, []}

  @doc "Links stored attachments to the activity created from the message."
  def link(stored, activity_id) do
    Enum.each(stored, &Uploads.link_activity(&1, activity_id))
  end

  @doc "Deletes stored attachments of a message that did not become an activity."
  def discard(stored), do: Enum.each(stored, &Uploads.delete_attachment/1)

  defp download?(channel), do: (channel.config || %{})["download_media"] not in [false, "false"]

  defp store_one(channel, conversation, attachment)
       when is_map(attachment) and not is_map_key(attachment, "contentUrl") do
    case Adapter.fetch_media(channel, attachment) do
      {:ok, %{data: data} = media} when is_binary(data) ->
        filename = attachment["name"] || media[:filename]

        case Uploads.create_attachment(channel.tenant_id, {filename, data},
               conversation_id: conversation.id
             ) do
          {:ok, stored} ->
            {stored_descriptor(attachment, stored), stored}

          {:error, reason} ->
            failed(channel, attachment, reason)
        end

      {:error, reason} ->
        failed(channel, attachment, reason)

      _skip_or_unsupported ->
        {attachment, nil}
    end
  end

  defp store_one(_channel, _conversation, attachment), do: {attachment, nil}

  defp stored_descriptor(attachment, %Attachment{} = stored) do
    attachment
    |> Map.merge(%{
      "contentUrl" => ConvergerWeb.Endpoint.url() <> "/api/v1/converger/attachments/#{stored.id}",
      "contentType" => stored.content_type,
      "size" => stored.size
    })
    |> then(fn a -> if stored.filename, do: Map.put(a, "name", stored.filename), else: a end)
  end

  defp failed(channel, attachment, reason) do
    Logger.warning("Inbound media download failed; keeping the provider reference",
      channel_id: channel.id,
      reason: inspect(reason)
    )

    channel_data =
      Map.put(attachment["channelData"] || %{}, "downloadError", error_text(reason))

    {Map.put(attachment, "channelData", channel_data), nil}
  end

  defp error_text(:too_large), do: "too_large"
  defp error_text({:unsupported_type, type}), do: "unsupported_type: #{type}"
  defp error_text({:http_error, status}), do: "http_error: #{status}"
  defp error_text(%Ecto.Changeset{}), do: "invalid_attachment"
  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)
end
