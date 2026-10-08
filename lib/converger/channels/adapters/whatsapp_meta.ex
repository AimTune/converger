defmodule Converger.Channels.Adapters.WhatsAppMeta do
  @behaviour Converger.Channels.Adapter

  alias Converger.Channels.InboundSignature
  alias Converger.Participants

  require Logger

  @default_graph_api_version "v23.0"

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

    recipient =
      activity.metadata["recipient_phone"] || activity.metadata["to"] ||
        Participants.recipient_for(activity, Map.get(channel, :id))

    if is_nil(recipient) do
      {:error,
       "no recipient: set activity metadata 'recipient_phone' or 'to', or reply in a conversation with a participant on this channel"}
    else
      url = "https://graph.facebook.com/#{graph_api_version(channel)}/#{phone_number_id}/messages"

      payload = %{
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: recipient,
        type: "text",
        text: %{body: activity.text}
      }

      req_options =
        Keyword.merge(
          [
            json: payload,
            headers: [{"authorization", "Bearer #{access_token}"}],
            receive_timeout: 15_000
          ],
          Application.get_env(:converger, :whatsapp_req_options, [])
        )

      case Req.post(url, req_options) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          {:ok, %{whatsapp_message_id: get_in(body, ["messages", Access.at(0), "id"])}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "WhatsApp API returned #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "WhatsApp API request failed: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Graph API version used for outbound calls. Resolution order: the channel
  config key `"graph_api_version"`, then
  `config :converger, Converger.Channels.Adapters.WhatsAppMeta, graph_api_version: "..."`,
  then #{@default_graph_api_version}.
  """
  def graph_api_version(channel \\ %{config: %{}}) do
    config = Map.get(channel, :config) || %{}

    case config["graph_api_version"] do
      version when is_binary(version) and version != "" ->
        version

      _ ->
        :converger
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:graph_api_version, @default_graph_api_version)
    end
  end

  @doc """
  Parses every message of a Cloud API webhook. Meta batches several
  `entry` / `changes` / `messages` into one call; each message becomes one
  parsed message with its `wamid` as `"idempotency_key"`.

  Returns `{:ok, []}` for a well-formed payload without messages (statuses
  only, or other webhook fields), and `{:error, _}` for a payload that is not
  a Cloud API webhook at all.
  """
  @impl true
  def parse_inbound(_channel, %{"entry" => entries}) when is_list(entries) do
    messages =
      Enum.flat_map(change_values(entries), fn value ->
        contacts = list(value["contacts"])

        for message <- list(value["messages"]),
            is_map(message),
            do: parse_message(message, value, contacts)
      end)

    {:ok, messages}
  end

  def parse_inbound(_channel, _params),
    do: {:error, "unable to parse WhatsApp Meta webhook payload"}

  defp change_values(entries) do
    for entry <- entries,
        is_map(entry),
        change <- list(entry["changes"]),
        is_map(change),
        is_map(change["value"]),
        do: change["value"]
  end

  defp list(value) when is_list(value), do: value
  defp list(_), do: []

  defp parse_message(message, value, contacts) do
    type = message["type"] || "text"
    from = message["from"]
    {activity_type, text, attachments, extra} = parse_content(type, message)

    metadata =
      %{
        "whatsapp_message_id" => message["id"],
        "whatsapp_type" => type,
        "timestamp" => message["timestamp"],
        "phone_number_id" => get_in(value, ["metadata", "phone_number_id"]),
        "profile_name" => profile_name(contacts, from),
        "reply_to" => get_in(message, ["context", "id"]),
        "forwarded" => get_in(message, ["context", "forwarded"])
      }
      |> Map.merge(extra)
      |> reject_nil_values()

    %{
      "sender" => from,
      "text" => text,
      "type" => activity_type,
      "attachments" => attachments,
      "metadata" => metadata,
      "idempotency_key" => message["id"],
      "participant" => %{"external_id" => from, "display_name" => metadata["profile_name"]}
    }
  end

  @media_types ~w(image audio video document sticker)

  # Returns {activity_type, text, attachments, extra_metadata}.
  defp parse_content("text", message),
    do: {"message", get_in(message, ["text", "body"]) || "", [], %{}}

  defp parse_content(type, message) when type in @media_types do
    media = message[type] || %{}

    attachment =
      reject_nil_values(%{
        "contentType" => media["mime_type"] || "application/octet-stream",
        "name" => media["filename"],
        "provider" => "whatsapp_meta",
        "providerMediaId" => media["id"],
        "sha256" => media["sha256"],
        "voice" => media["voice"],
        "animated" => media["animated"]
      })

    {"message", media["caption"] || "", [attachment], %{}}
  end

  defp parse_content("location", message) do
    location = message["location"] || %{}

    content =
      reject_nil_values(%{
        "latitude" => location["latitude"],
        "longitude" => location["longitude"],
        "name" => location["name"],
        "address" => location["address"],
        "url" => location["url"]
      })

    text = Enum.join(Enum.reject([location["name"], location["address"]], &is_nil/1), ", ")

    {"message", text,
     [%{"contentType" => "application/vnd.converger.location", "content" => content}], %{}}
  end

  defp parse_content("contacts", message) do
    contacts =
      message
      |> Map.get("contacts")
      |> list()
      |> Enum.map(fn contact ->
        reject_nil_values(%{
          "name" => get_in(contact, ["name", "formatted_name"]),
          "phones" =>
            contact |> Map.get("phones") |> list() |> Enum.map(&(&1["wa_id"] || &1["phone"]))
        })
      end)

    names = contacts |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1) |> Enum.join(", ")

    {"message", names,
     [%{"contentType" => "application/vnd.converger.contacts", "content" => contacts}], %{}}
  end

  defp parse_content("interactive", message) do
    interactive = message["interactive"] || %{}
    reply = interactive["button_reply"] || interactive["list_reply"] || %{}

    {"message", reply["title"] || "", [],
     %{
       "interactive_reply" =>
         reject_nil_values(%{
           "type" => interactive["type"],
           "id" => reply["id"],
           "title" => reply["title"],
           "description" => reply["description"]
         })
     }}
  end

  defp parse_content("button", message) do
    button = message["button"] || %{}

    {"message", button["text"] || "", [],
     %{
       "interactive_reply" =>
         reject_nil_values(%{"type" => "button", "payload" => button["payload"]})
     }}
  end

  defp parse_content("reaction", message) do
    reaction = message["reaction"] || %{}

    {"event", reaction["emoji"] || "", [],
     %{
       "reaction" =>
         reject_nil_values(%{
           "message_id" => reaction["message_id"],
           "emoji" => reaction["emoji"]
         })
     }}
  end

  defp parse_content("system", message),
    do: {"event", get_in(message, ["system", "body"]) || "", [], %{}}

  # unsupported, order, unknown future types: keep the activity (no silent
  # loss) and let consumers look at metadata.whatsapp_type.
  defp parse_content(_type, message),
    do: {"message", get_in(message, ["text", "body"]) || "", [], %{}}

  defp profile_name(contacts, from) do
    contact =
      Enum.find(contacts, fn contact -> is_map(contact) and contact["wa_id"] == from end) ||
        case contacts do
          [only] -> only
          _ -> nil
        end

    if is_map(contact), do: get_in(contact, ["profile", "name"])
  end

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
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
  def parse_status_update(_channel, %{"entry" => entries}) when is_list(entries) do
    updates =
      for value <- change_values(entries),
          status <- list(value["statuses"]),
          is_map(status) do
        %{
          "provider_message_id" => status["id"],
          "status" => normalize_status(status["status"]),
          "timestamp" => status["timestamp"],
          "recipient_id" => status["recipient_id"],
          "error" => extract_error(status)
        }
      end

    case updates do
      [] -> :ignore
      updates -> {:ok, updates}
    end
  end

  def parse_status_update(_channel, _params), do: :ignore

  defp normalize_status("sent"), do: "sent"
  defp normalize_status("delivered"), do: "delivered"
  defp normalize_status("read"), do: "read"
  defp normalize_status("failed"), do: "failed"
  defp normalize_status(_), do: "sent"

  defp extract_error(%{"errors" => [%{"title" => title} | _]}), do: title
  defp extract_error(_), do: nil
end
