defmodule Converger.Channels.Adapters.WhatsAppInfobip do
  @behaviour Converger.Channels.Adapter

  require Logger

  @impl true
  def supported_modes, do: ~w(inbound outbound duplex)

  @impl true
  def validate_config(config) do
    required = ["base_url", "api_key", "sender"]
    missing = Enum.filter(required, fn key -> !is_binary(config[key]) or config[key] == "" end)

    case missing do
      [] -> :ok
      fields -> {:error, "whatsapp_infobip config missing: #{Enum.join(fields, ", ")}"}
    end
  end

  @impl true
  def deliver_activity(channel, activity) do
    base_url = channel.config["base_url"]
    api_key = channel.config["api_key"]
    sender = channel.config["sender"]
    recipient = activity.metadata["recipient_phone"] || activity.metadata["to"]

    if is_nil(recipient) do
      {:error, "activity metadata must include 'recipient_phone' or 'to' for Infobip delivery"}
    else
      url = "#{base_url}/whatsapp/1/message/text"

      payload = %{
        from: sender,
        to: recipient,
        content: %{text: activity.text}
      }

      case Req.post(url,
             json: payload,
             headers: [
               {"authorization", "App #{api_key}"},
               {"content-type", "application/json"}
             ],
             receive_timeout: 15_000
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          message_id = get_in(body, ["messages", Access.at(0), "messageId"])
          {:ok, %{infobip_message_id: message_id}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "Infobip API returned #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Infobip API request failed: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Parses every inbound message of an Infobip webhook (`results` is a batch).
  Each message gets its Infobip `messageId` as `"idempotency_key"`. Delivery
  reports (results with a `status`) are not messages and are skipped here;
  see `parse_status_update/2`.
  """
  @impl true
  def parse_inbound(_channel, %{"results" => results}) when is_list(results) do
    messages =
      for result <- results,
          is_map(result),
          not delivery_report?(result),
          do: parse_message(result)

    {:ok, messages}
  end

  def parse_inbound(_channel, _params), do: {:error, "unable to parse Infobip webhook payload"}

  defp delivery_report?(result), do: match?(%{"groupName" => _}, result["status"])

  defp parse_message(result) do
    message = if is_map(result["message"]), do: result["message"], else: %{}
    type = message["type"] || "TEXT"
    {activity_type, text, attachments, extra} = parse_content(type, message, result)

    metadata =
      %{
        "infobip_message_id" => result["messageId"],
        "whatsapp_type" => String.downcase(type),
        "received_at" => result["receivedAt"],
        "profile_name" => get_in(result, ["contact", "name"]),
        "reply_to" => get_in(message, ["context", "id"])
      }
      |> Map.merge(extra)
      |> reject_nil_values()

    %{
      "sender" => result["from"],
      "text" => text,
      "type" => activity_type,
      "attachments" => attachments,
      "metadata" => metadata,
      "idempotency_key" => result["messageId"]
    }
  end

  @media_types %{
    "IMAGE" => "image/*",
    "VIDEO" => "video/*",
    "AUDIO" => "audio/*",
    "VOICE" => "audio/*",
    "DOCUMENT" => "application/octet-stream",
    "STICKER" => "image/webp"
  }

  # Returns {activity_type, text, attachments, extra_metadata}.
  defp parse_content("TEXT", message, result),
    do: {"message", message["text"] || result["text"] || "", [], %{}}

  defp parse_content(type, message, _result) when is_map_key(@media_types, type) do
    attachment =
      reject_nil_values(%{
        "contentType" => message["mimeType"] || Map.fetch!(@media_types, type),
        "name" => message["filename"] || message["fileName"],
        "provider" => "whatsapp_infobip",
        "providerMediaId" => message["id"],
        "providerMediaUrl" => message["url"]
      })

    {"message", message["caption"] || "", [attachment], %{}}
  end

  defp parse_content("LOCATION", message, _result) do
    content =
      reject_nil_values(%{
        "latitude" => message["latitude"],
        "longitude" => message["longitude"],
        "name" => message["name"],
        "address" => message["address"],
        "url" => message["url"]
      })

    text = Enum.join(Enum.reject([message["name"], message["address"]], &is_nil/1), ", ")

    {"message", text,
     [%{"contentType" => "application/vnd.converger.location", "content" => content}], %{}}
  end

  defp parse_content(type, message, _result)
       when type in ["INTERACTIVE_BUTTON_REPLY", "INTERACTIVE_LIST_REPLY", "BUTTON"] do
    {"message", message["title"] || message["text"] || "", [],
     %{
       "interactive_reply" =>
         reject_nil_values(%{
           "type" => String.downcase(type),
           "id" => message["id"],
           "title" => message["title"],
           "description" => message["description"],
           "payload" => message["payload"]
         })
     }}
  end

  # CONTACT, ORDER, UNSUPPORTED and future types: keep the activity (no
  # silent loss); consumers can look at metadata.whatsapp_type.
  defp parse_content(_type, message, result),
    do: {"message", message["text"] || result["text"] || "", [], %{}}

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  @impl true
  def parse_status_update(_channel, %{"results" => results}) when is_list(results) do
    updates =
      for result <- results,
          is_map(result),
          delivery_report?(result) do
        %{
          "provider_message_id" => result["messageId"],
          "status" => normalize_dlr_status(result["status"]["groupName"]),
          "timestamp" => result["doneAt"] || result["sentAt"],
          "recipient_id" => result["to"],
          "error" => get_in(result, ["error", "description"])
        }
      end

    case updates do
      [] -> :ignore
      updates -> {:ok, updates}
    end
  end

  def parse_status_update(_channel, _params), do: :ignore

  defp normalize_dlr_status("DELIVERED"), do: "delivered"
  defp normalize_dlr_status("SEEN"), do: "read"
  defp normalize_dlr_status("REJECTED"), do: "failed"
  defp normalize_dlr_status("UNDELIVERABLE"), do: "failed"
  defp normalize_dlr_status("PENDING"), do: "sent"
  defp normalize_dlr_status(_), do: "sent"
end
