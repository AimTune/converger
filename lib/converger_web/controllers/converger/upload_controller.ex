defmodule ConvergerWeb.ConvergerAPI.UploadController do
  use ConvergerWeb, :controller

  alias Converger.{Activities, Conversations, Uploads}
  import ConvergerWeb.Helpers.Authorization, only: [authorize_conversation: 2]

  require Logger

  plug ConvergerWeb.Plugs.RateLimit, bucket: :upload, scope: :tenant

  action_fallback ConvergerWeb.FallbackController

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    claims = conn.assigns.converger_claims
    tenant_id = claims["tenant_id"]

    with :ok <- authorize_conversation(claims, conversation_id),
         %Conversations.Conversation{} = _conversation <-
           Conversations.get_conversation(conversation_id, tenant_id),
         {:ok, attachment} <- upload_file(params, tenant_id, conversation_id) do
      # Parse optional activity JSON from multipart
      activity_meta = parse_activity_metadata(params)
      content_url = url(~p"/api/v1/converger/attachments/#{attachment.id}")

      activity_params = %{
        "type" => activity_meta["type"] || "message",
        "sender" => get_in(activity_meta, ["from", "id"]) || "user",
        "text" => activity_meta["text"] || "",
        "attachments" => [
          %{
            "contentType" => attachment.content_type,
            "contentUrl" => content_url,
            "name" => attachment.filename,
            "size" => attachment.size
          }
        ],
        "metadata" => activity_meta["channelData"] || activity_meta["metadata"] || %{},
        "tenant_id" => tenant_id,
        "conversation_id" => conversation_id
      }

      case Activities.create_activity(activity_params) do
        {:ok, activity} ->
          {:ok, _} = Uploads.link_activity(attachment, activity.id)

          conn
          |> put_status(:ok)
          |> json(%{
            id: activity.id,
            attachments: [
              %{
                id: attachment.id,
                contentType: attachment.content_type,
                contentUrl: content_url,
                size: attachment.size
              }
            ]
          })

        {:error, reason} ->
          _ = Uploads.delete_attachment(attachment)
          {:error, reason}
      end
    else
      nil ->
        {:error, :not_found}

      {:error, :too_large} ->
        max_mb = Float.round(Uploads.max_file_size() / (1024 * 1024), 1)

        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: "File too large (max #{max_mb}MB)"})

      {:error, {:unsupported_type, type}} ->
        conn
        |> put_status(:unsupported_media_type)
        |> json(%{error: "File type #{type} is not allowed"})

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, %Ecto.Changeset{}} = error ->
        error

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("Attachment upload failed: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "File could not be stored, please retry"})
    end
  end

  defp upload_file(%{"file" => %Plug.Upload{} = upload}, tenant_id, conversation_id) do
    Uploads.create_attachment(tenant_id, upload, conversation_id: conversation_id)
  end

  defp upload_file(_, _, _), do: {:error, "Missing file in upload"}

  defp parse_activity_metadata(%{"activity" => activity_json}) when is_binary(activity_json) do
    case Jason.decode(activity_json) do
      {:ok, meta} -> meta
      {:error, _} -> %{}
    end
  end

  defp parse_activity_metadata(%{"activity" => meta}) when is_map(meta), do: meta
  defp parse_activity_metadata(_), do: %{}
end
