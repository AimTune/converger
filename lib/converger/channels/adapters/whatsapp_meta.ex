defmodule Converger.Channels.Adapters.WhatsAppMeta do
  @behaviour Converger.Channels.Adapter

  require Logger

  @graph_api_version "v18.0"

  @impl true
  def supported_modes, do: ~w(inbound outbound duplex)

  @impl true
  def validate_config(config) do
    required = ["phone_number_id", "access_token", "verify_token"]
    missing = Enum.filter(required, fn key -> !is_binary(config[key]) or config[key] == "" end)

    case missing do
      [] -> :ok
      fields -> {:error, "whatsapp_meta config missing: #{Enum.join(fields, ", ")}"}
    end
  end

  @impl true
  def deliver_activity(channel, activity) do
    phone_number_id = channel.config["phone_number_id"]
    access_token = channel.config["access_token"]
    recipient = activity.metadata["recipient_phone"] || activity.metadata["to"]

    if is_nil(recipient) do
      {:error, "activity metadata must include 'recipient_phone' or 'to' for WhatsApp delivery"}
    else
      url = "https://graph.facebook.com/#{@graph_api_version}/#{phone_number_id}/messages"

      payload = %{
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: recipient,
        type: "text",
        text: %{body: activity.text}
      }

      case Req.post(url,
             json: payload,
             headers: [{"authorization", "Bearer #{access_token}"}],
             receive_timeout: 15_000
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          {:ok, %{whatsapp_message_id: get_in(body, ["messages", Access.at(0), "id"])}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "WhatsApp API returned #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "WhatsApp API request failed: #{inspect(reason)}"}
      end
    end
  end

  @impl true
  def parse_inbound(_channel, params) do
    with [entry | _] <- params["entry"] || [],
         [change | _] <- entry["changes"] || [],
         value <- change["value"],
         [message | _] <- value["messages"] || [] do
      {:ok,
       %{
         "sender" => message["from"],
         "text" => get_in(message, ["text", "body"]) || "",
         "type" => "message",
         "metadata" => %{
           "whatsapp_message_id" => message["id"],
           "timestamp" => message["timestamp"],
           "phone_number_id" => value["metadata"]["phone_number_id"]
         }
       }}
    else
      _ -> {:error, "unable to parse WhatsApp Meta webhook payload"}
    end
  end

  @impl true
  def parse_status_update(_channel, params) do
    with [entry | _] <- params["entry"] || [],
         [change | _] <- entry["changes"] || [],
         value <- change["value"],
         statuses when is_list(statuses) and statuses != [] <- value["statuses"] do
      updates =
        Enum.map(statuses, fn status ->
          %{
            "provider_message_id" => status["id"],
            "status" => normalize_status(status["status"]),
            "timestamp" => status["timestamp"],
            "recipient_id" => status["recipient_id"],
            "error" => extract_error(status)
          }
        end)

      {:ok, updates}
    else
      _ -> :ignore
    end
  end

  defp normalize_status("sent"), do: "sent"
  defp normalize_status("delivered"), do: "delivered"
  defp normalize_status("read"), do: "read"
  defp normalize_status("failed"), do: "failed"
  defp normalize_status(_), do: "sent"

  defp extract_error(%{"errors" => [%{"title" => title} | _]}), do: title
  defp extract_error(_), do: nil
end
