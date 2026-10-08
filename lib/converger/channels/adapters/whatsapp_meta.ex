defmodule Converger.Channels.Adapters.WhatsAppMeta do
  @behaviour Converger.Channels.Adapter

  alias Converger.Channels.{DeliveryError, InboundSignature}
  alias Converger.Pipeline.RetryPolicy

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
      {:error,
       DeliveryError.permanent(
         "activity metadata must include 'recipient_phone' or 'to' for WhatsApp delivery"
       )}
    else
      url = "https://graph.facebook.com/#{@graph_api_version}/#{phone_number_id}/messages"

      payload = %{
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: recipient,
        type: "text",
        text: %{body: activity.text}
      }

      options =
        [
          json: payload,
          headers: [{"authorization", "Bearer #{access_token}"}],
          receive_timeout: RetryPolicy.for_channel(channel).timeout_ms
        ]
        |> Keyword.merge(Application.get_env(:converger, :whatsapp_req_options, []))

      case Req.post(url, options) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          {:ok, %{whatsapp_message_id: get_in(body, ["messages", Access.at(0), "id"])}}

        # 400 (e.g. invalid recipient) and auth errors are permanent; 429 and
        # 5xx are retried, honouring Retry-After.
        {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
          {:error, DeliveryError.from_http(status, headers, body, "WhatsApp API")}

        {:error, reason} ->
          {:error, DeliveryError.from_transport(reason, "WhatsApp API")}
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

  @doc """
  Verifies Meta's `X-Hub-Signature-256` header (`sha256=<hex HMAC-SHA256 of
  the raw body, keyed with the app secret>`). The app secret is read from
  the channel config key `"app_secret"`.

  Returns `:missing` when the header is absent or no `app_secret` is
  configured, so the controller can apply the channel's `require_signature`
  policy.
  """
  @impl true
  def verify_inbound_signature(channel, headers, raw_body) do
    app_secret = (channel.config || %{})["app_secret"]

    case InboundSignature.get_header(headers, "x-hub-signature-256") do
      nil ->
        :missing

      _signature when not is_binary(app_secret) or app_secret == "" ->
        :missing

      signature ->
        expected = "sha256=" <> InboundSignature.hmac_hex(app_secret, raw_body || "")

        if Plug.Crypto.secure_compare(expected, String.downcase(signature)),
          do: :ok,
          else: {:error, :invalid_signature}
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
