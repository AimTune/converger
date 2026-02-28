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

  @impl true
  def parse_inbound(_channel, params) do
    with [result | _] <- params["results"] || [] do
      {:ok,
       %{
         "sender" => result["from"],
         "text" => get_in(result, ["message", "text"]) || result["text"] || "",
         "type" => "message",
         "metadata" => %{
           "infobip_message_id" => result["messageId"],
           "received_at" => result["receivedAt"]
         }
       }}
    else
      _ -> {:error, "unable to parse Infobip webhook payload"}
    end
  end

  @impl true
  def parse_status_update(_channel, params) do
    with [result | _] <- params["results"] || [],
         %{"groupName" => group_name} <- result["status"] do
      updates = [
        %{
          "provider_message_id" => result["messageId"],
          "status" => normalize_dlr_status(group_name),
          "timestamp" => result["doneAt"] || result["sentAt"],
          "recipient_id" => result["to"],
          "error" => get_in(result, ["error", "description"])
        }
      ]

      {:ok, updates}
    else
      _ -> :ignore
    end
  end

  defp normalize_dlr_status("DELIVERED"), do: "delivered"
  defp normalize_dlr_status("SEEN"), do: "read"
  defp normalize_dlr_status("REJECTED"), do: "failed"
  defp normalize_dlr_status("UNDELIVERABLE"), do: "failed"
  defp normalize_dlr_status("PENDING"), do: "sent"
  defp normalize_dlr_status(_), do: "sent"
end
