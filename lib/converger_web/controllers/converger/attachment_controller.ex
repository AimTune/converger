defmodule ConvergerWeb.ConvergerAPI.AttachmentController do
  @moduledoc """
  `GET /api/v1/converger/attachments/:id`

  Authenticated (converger token): an attachment of another tenant, of a
  conversation on another channel, or of another conversation when the
  token is bound to one, is reported as 404. Local files are streamed; cloud
  backends redirect (302) to a short-lived signed storage or CDN URL.
  """
  use ConvergerWeb, :controller

  alias Converger.{Conversations, Uploads}
  alias Converger.Uploads.Attachment
  alias ConvergerWeb.Helpers.Authorization

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Not Found"}})
  end

  def show(conn, %{"id" => id}) do
    claims = conn.assigns.converger_claims

    with %Attachment{} = attachment <- Uploads.get_attachment(claims["tenant_id"], id),
         :ok <- authorize_conversation(claims, attachment) do
      send_attachment(conn, attachment, Uploads.download(attachment))
    else
      _ -> not_found(conn)
    end
  end

  # The attachment's conversation must be visible to the token: bound to it
  # (conversation tokens) and on the token's channel (every token).
  # Attachments without a conversation are never served through this API.
  defp authorize_conversation(claims, %Attachment{conversation_id: conversation_id})
       when is_binary(conversation_id) do
    with :ok <- Authorization.authorize_conversation(claims, conversation_id),
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, claims["tenant_id"]),
         :ok <- Authorization.authorize_channel(claims, conversation) do
      :ok
    else
      _ -> :not_found
    end
  end

  defp authorize_conversation(_claims, _attachment), do: :not_found

  defp send_attachment(conn, _attachment, {:redirect, url}) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> redirect(external: url)
  end

  # `path` comes from the storage backend (LocalStorage.path_for/2 confines
  # it to the upload directory), never from the request.
  # sobelow_skip ["Traversal.SendFile"]
  defp send_attachment(conn, attachment, {:file, path}) do
    conn
    |> put_file_headers(attachment)
    |> send_file(200, path)
  end

  # Stored bytes are served with nosniff, a sandboxing CSP and a
  # content-disposition header (see put_file_headers/2).
  # sobelow_skip ["XSS.SendResp"]
  defp send_attachment(conn, attachment, {:data, data}) do
    conn
    |> put_file_headers(attachment)
    |> send_resp(200, data)
  end

  defp send_attachment(conn, _attachment, {:error, :not_found}), do: not_found(conn)

  defp send_attachment(conn, _attachment, {:error, _reason}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "Attachment storage unavailable"})
  end

  # The content type was sniffed and allow-listed at upload time
  # (Converger.Uploads.MimeSniffer), not taken from the request.
  # sobelow_skip ["XSS.ContentType"]
  defp put_file_headers(conn, attachment) do
    conn
    |> put_resp_content_type(attachment.content_type, charset(attachment.content_type))
    |> put_resp_header("content-disposition", Uploads.content_disposition(attachment))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> put_resp_header("cache-control", "private, max-age=300")
    |> put_resp_header("etag", ~s("#{attachment.sha256}"))
  end

  # Text is only sniffed as text/plain when it is valid UTF-8.
  defp charset("text/" <> _), do: "utf-8"
  defp charset(_), do: nil
end
