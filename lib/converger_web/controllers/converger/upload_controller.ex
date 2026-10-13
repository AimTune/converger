defmodule ConvergerWeb.ConvergerAPI.UploadController do
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.{Activities, Conversations, Uploads}
  alias ConvergerWeb.APIError

  import ConvergerWeb.Helpers.Authorization,
    only: [authorize_channel: 2, authorize_conversation: 2]

  require Logger

  plug ConvergerWeb.Plugs.RateLimit, bucket: :upload, scope: :tenant

  # Token permissions (ADR-0059).
  plug ConvergerWeb.Plugs.RequirePermission, "write"

  action_fallback ConvergerWeb.FallbackController

  tags(["Client: Uploads"])
  security([%{"convergerToken" => []}])

  operation(:create,
    summary: "Upload a file",
    description:
      "Stores the file (type sniffed and allow-listed) and posts an activity carrying it.",
    operation_id: "uploadFile",
    parameters: [conversation_id: path_id("Conversation id")],
    request_body: {"The file", "multipart/form-data", ref("UploadRequest")},
    responses:
      with_errors(
        %{200 => json_schema("Uploaded", ref("UploadResponse"))},
        [400, 401, 403, 404, 409, 413, 415, 422, 429, 502]
      )
  )

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    claims = conn.assigns.converger_claims
    tenant_id = claims["tenant_id"]

    with :ok <- authorize_conversation(claims, conversation_id),
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, tenant_id),
         :ok <- authorize_channel(claims, conversation),
         # Fail fast before storing the file; create_activity re-checks atomically.
         :ok <- Conversations.ensure_open(conversation),
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
        "reply_to_id" => activity_meta["replyToId"],
        "tenant_id" => tenant_id,
        "conversation_id" => conversation_id,
        "source_channel_id" => claims["channel_id"]
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

        {:error,
         APIError.new(:payload_too_large, "File too large (max #{max_mb}MB)", %{
           max_bytes: Uploads.max_file_size()
         })}

      {:error, {:unsupported_type, type}} ->
        {:error,
         APIError.new(:unsupported_media_type, "File type #{type} is not allowed", %{
           content_type: type
         })}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, %Ecto.Changeset{}} = error ->
        error

      # Handled by the fallback controller (409 for a closed conversation).
      {:error, reason} when reason in [:forbidden, :not_found, :conversation_closed] ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("Attachment upload failed: #{inspect(reason)}")
        {:error, APIError.new(:upstream_unavailable, "File could not be stored, please retry")}
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
