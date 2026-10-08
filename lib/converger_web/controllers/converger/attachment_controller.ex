defmodule ConvergerWeb.ConvergerAPI.AttachmentController do
  @moduledoc """
  `GET /api/v1/converger/attachments/:id`

  Authenticated (converger token) and tenant scoped: an attachment of
  another tenant, or of another conversation when the token is bound to a
  conversation, is reported as 404. Local files are streamed; cloud
  backends redirect (302) to a short-lived signed storage or CDN URL.
  """
  use ConvergerWeb, :controller

  alias Converger.Uploads
  alias Converger.Uploads.Attachment

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

  defp authorize_conversation(%{"conversation_id" => conv_id}, %Attachment{conversation_id: id})
       when is_binary(conv_id) and is_binary(id) and conv_id != id,
       do: :not_found

  defp authorize_conversation(_claims, _attachment), do: :ok

  defp send_attachment(conn, _attachment, {:redirect, url}) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> redirect(external: url)
  end

  defp send_attachment(conn, attachment, {:file, path}) do
    conn
    |> put_file_headers(attachment)
    |> send_file(200, path)
  end

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
