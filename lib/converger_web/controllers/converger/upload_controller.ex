defmodule ConvergerWeb.ConvergerAPI.UploadController do
  use ConvergerWeb, :controller

  alias Converger.{Activities, Conversations, Uploads}
  import ConvergerWeb.Helpers.Authorization, only: [authorize_conversation: 2]

  action_fallback ConvergerWeb.FallbackController

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    claims = conn.assigns.converger_claims

    with :ok <- authorize_conversation(claims, conversation_id),
         %Conversations.Conversation{} = _conversation <-
           Conversations.get_conversation(conversation_id, claims["tenant_id"]),
         {:ok, file_result} <- upload_file(params, claims["tenant_id"]) do
      # Parse optional activity JSON from multipart
      activity_meta = parse_activity_metadata(params)

      activity_params = %{
        "type" => activity_meta["type"] || "message",
        "sender" => get_in(activity_meta, ["from", "id"]) || "user",
        "text" => activity_meta["text"] || "",
        "attachments" => [
          %{
            "contentType" => file_result[:content_type],
            "contentUrl" => file_result.url,
            "name" => file_result[:filename],
            "size" => file_result.size
          }
        ],
        "metadata" => activity_meta["channelData"] || activity_meta["metadata"] || %{},
        "tenant_id" => claims["tenant_id"],
        "conversation_id" => conversation_id
      }

      case Activities.create_activity(activity_params) do
        {:ok, activity} ->
          conn
          |> put_status(:ok)
          |> json(%{id: activity.id})

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
      {:error, message} when is_binary(message) -> {:error, message}
      error -> error
    end
  end

  defp upload_file(%{"file" => %Plug.Upload{} = upload}, tenant_id) do
    case Uploads.store_file(upload, tenant_id: tenant_id) do
      {:ok, result} ->
        {:ok,
         Map.merge(result, %{
           content_type: upload.content_type,
           filename: upload.filename
         })}

      error ->
        error
    end
  end

  defp upload_file(_, _), do: {:error, "Missing file in upload"}

  defp parse_activity_metadata(%{"activity" => activity_json}) when is_binary(activity_json) do
    case Jason.decode(activity_json) do
      {:ok, meta} -> meta
      {:error, _} -> %{}
    end
  end

  defp parse_activity_metadata(%{"activity" => meta}) when is_map(meta), do: meta
  defp parse_activity_metadata(_), do: %{}

end
