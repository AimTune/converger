defmodule Converger.Channels.Adapters.WhatsAppInfobip do
  use Converger.Channels.Adapter, type: "whatsapp_infobip"

  alias Converger.Channels.{DeliveryError, MediaDownload, UrlGuard}
  alias Converger.Channels.WhatsApp.Outbound
  alias Converger.{Participants, Uploads}
  alias Converger.Pipeline.RetryPolicy

  require Logger

  # `message` activities are sent as text, media, template, interactive,
  # location and contacts messages (Converger.Channels.WhatsApp.Outbound).
  # Other activity types are downgraded to text or skipped
  # (Converger.Activities.Downgrade).
  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :receipts,
      :provider_ack,
      :media,
      :templates,
      activity_types: ~w(message)
    ]
  end

  @impl true
  def config_schema do
    [
      %{
        name: "base_url",
        type: :url,
        required: true,
        label: "Base URL",
        placeholder: "https://xxxxx.api.infobip.com"
      },
      %{
        name: "api_key",
        type: :string,
        required: true,
        secret: true,
        label: "API Key",
        placeholder: "Infobip API key"
      },
      %{
        name: "sender",
        type: :string,
        required: true,
        label: "Sender",
        placeholder: "Sender phone number",
        summary: true
      },
      %{
        name: "download_media",
        type: :boolean,
        label: "Download inbound media",
        help: "Store inbound images, audio and documents in Converger (default true)"
      }
    ]
  end

  # base_url is per-tenant config the server sends requests to: same SSRF
  # guard as webhook channels.
  @impl true
  def validate_config(config) do
    case UrlGuard.check(config["base_url"]) do
      :ok -> :ok
      {:error, message} -> {:error, "whatsapp_infobip config base_url is not allowed: #{message}"}
    end
  end

  @impl true
  def deliver_activity(channel, activity) do
    recipient =
      activity.metadata["recipient_phone"] || activity.metadata["to"] ||
        Participants.recipient_for(activity, Map.get(channel, :id))

    with {:ok, recipient} <- require_recipient(recipient),
         :ok <- check_target(channel.config["base_url"]),
         {:ok, parts} <- Outbound.parts(activity) do
      send_parts(channel, recipient, parts)
    end
  end

  # One WhatsApp message per part, in order; the first message id is the
  # delivery's provider_message_id. See WhatsAppMeta.send_parts/3.
  defp send_parts(channel, recipient, parts) do
    result =
      Enum.reduce_while(parts, [], fn part, ids ->
        with {:ok, path, body} <- render(channel, recipient, part),
             {:ok, id} <- post(channel, path, body) do
          {:cont, [id | ids]}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:error, _} = error ->
        error

      ids ->
        [first | _] = ids = Enum.reverse(ids)

        {:ok, %{infobip_message_id: first, provider_message_id: first, infobip_message_ids: ids}}
    end
  end

  # Returns {:ok, path, body}.
  defp render(channel, to, {:text, text}),
    do: {:ok, "/whatsapp/1/message/text", envelope(channel, to, %{text: text})}

  defp render(channel, to, {:template, template}) do
    message =
      envelope(channel, to, %{
        templateName: template["name"],
        templateData: template["templateData"] || template_data(template["components"]),
        language: template["language"]
      })

    {:ok, "/whatsapp/1/message/template", %{messages: [message]}}
  end

  defp render(channel, to, {:media, kind, attachment, caption}) do
    with {:ok, url} <- media_url(channel, attachment) do
      content =
        %{mediaUrl: url}
        |> put_present(:caption, caption)
        |> put_present(:filename, if(kind == "document", do: attachment["name"]))

      {:ok, "/whatsapp/1/message/#{kind}", envelope(channel, to, content)}
    end
  end

  defp render(channel, to, {:location, content}) do
    location =
      %{latitude: content["latitude"], longitude: content["longitude"]}
      |> put_present(:name, content["name"])
      |> put_present(:address, content["address"])

    {:ok, "/whatsapp/1/message/location", envelope(channel, to, location)}
  end

  defp render(channel, to, {:contacts, contacts}) do
    contacts =
      for contact <- contacts do
        name = contact["name"] || "Contact"
        phones = for phone <- List.wrap(contact["phones"]), is_binary(phone), do: %{phone: phone}
        %{name: %{firstName: name, formattedName: name}, phones: phones}
      end

    {:ok, "/whatsapp/1/message/contact", envelope(channel, to, %{contacts: contacts})}
  end

  defp render(channel, to, {:buttons, card}) do
    buttons = for b <- card["buttons"], do: %{type: "REPLY", id: b["id"], title: b["title"]}
    content = interactive(card, %{buttons: buttons})
    {:ok, "/whatsapp/1/message/interactive/buttons", envelope(channel, to, content)}
  end

  defp render(channel, to, {:list, card}) do
    sections =
      for s <- card["sections"] do
        rows =
          for r <- s["rows"],
              do: put_present(%{id: r["id"], title: r["title"]}, :description, r["description"])

        put_present(%{rows: rows}, :title, s["title"])
      end

    content = interactive(card, %{title: card["button"], sections: sections})
    {:ok, "/whatsapp/1/message/interactive/list", envelope(channel, to, content)}
  end

  defp envelope(channel, to, content),
    do: %{from: channel.config["sender"], to: to, content: content}

  defp interactive(card, action) do
    %{body: %{text: card["body"]}, action: action}
    |> put_present(:header, card["header"] && %{type: "TEXT", text: card["header"]})
    |> put_present(:footer, card["footer"] && %{text: card["footer"]})
  end

  # Infobip's templateData from Meta-style components: the body parameters'
  # texts become the body placeholders. Anything richer (header media,
  # buttons) goes in metadata.template.templateData as is.
  defp template_data(components) do
    placeholders =
      for %{"type" => type} = component <- List.wrap(components),
          String.downcase(type) == "body",
          parameter <- List.wrap(component["parameters"]),
          is_map(parameter),
          do: to_string(parameter["text"] || "")

    %{body: %{placeholders: placeholders}}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Infobip fetches media by URL. A file uploaded to Converger needs a URL
  # Infobip can reach: a signed storage or CDN URL (cloud backends); the
  # local-disk backend has none.
  defp media_url(channel, attachment) do
    case Outbound.media_source(channel, attachment, type()) do
      {:stored, stored} ->
        case Uploads.download(stored) do
          {:redirect, url} ->
            {:ok, url}

          _ ->
            {:error,
             DeliveryError.permanent(
               "Infobip fetches media by URL, and attachment #{stored.id} has no public URL: " <>
                 "configure a cloud storage backend or a CDN (see docs/storage.md)"
             )}
        end

      {:link, url} ->
        {:ok, url}

      {:provider_id, _id} ->
        case attachment["channelData"]["providerMediaUrl"] do
          url when is_binary(url) -> {:ok, url}
          _ -> {:error, DeliveryError.permanent("attachment has no usable contentUrl")}
        end

      {:error, _} = error ->
        error
    end
  end

  defp post(channel, path, body) do
    case Req.post(channel.config["base_url"] <> path, request_options(channel, json: body)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, message_id(body)}

      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:error, DeliveryError.from_http(status, headers, body, "Infobip API")}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, "Infobip API")}
    end
  end

  # Single-message endpoints answer {messageId, ...}; the template endpoint
  # answers {messages: [{messageId, ...}]}.
  defp message_id(%{"messageId" => id}), do: id
  defp message_id(body), do: get_in(body, ["messages", Access.at(0), "messageId"])

  defp request_options(channel, options) do
    [
      headers: [{"authorization", "App #{channel.config["api_key"]}"}],
      receive_timeout: RetryPolicy.for_channel(channel).timeout_ms
    ]
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:converger, :whatsapp_req_options, []))
  end

  @doc """
  Downloads an inbound media file from `channelData.providerMediaUrl` with
  the channel's API key. The URL comes from the webhook body, so it is only
  fetched when its host is the channel's `base_url` host: the API key is
  never sent anywhere else.
  """
  @impl true
  def fetch_media(channel, %{"channelData" => %{"providerMediaUrl" => url}})
      when is_binary(url) and url != "" do
    if same_host?(url, channel.config["base_url"]) do
      headers = [{"authorization", "App #{channel.config["api_key"]}"}]

      with :ok <- check_target(channel.config["base_url"]),
           {:ok, data} <- MediaDownload.get(url, headers: headers) do
        {:ok, %{data: data, filename: nil}}
      end
    else
      {:error, "media URL host is not the channel's base_url host"}
    end
  end

  def fetch_media(_channel, _attachment), do: :skip

  defp same_host?(url, base_url) when is_binary(base_url) do
    media = URI.parse(url)
    base = URI.parse(base_url)
    media.scheme == "https" and is_binary(media.host) and media.host == base.host
  end

  defp same_host?(_url, _base_url), do: false

  @doc """
  Lists the WhatsApp templates of the channel's sender
  (`GET <base_url>/whatsapp/2/senders/<sender>/templates`).
  """
  @impl true
  def list_templates(channel) do
    sender = URI.encode(channel.config["sender"] || "", &URI.char_unreserved?/1)
    url = "#{channel.config["base_url"]}/whatsapp/2/senders/#{sender}/templates"

    with :ok <- check_target(channel.config["base_url"]) do
      case Req.get(url, request_options(channel, retry: false, receive_timeout: 10_000)) do
        {:ok, %Req.Response{status: 200, body: %{"templates" => templates}}}
        when is_list(templates) ->
          {:ok,
           for t <- templates, is_map(t) do
             Map.take(t, ~w(id name language status category structure))
           end}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "Infobip API returned #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Infobip API request failed: #{inspect(reason)}"}
      end
    else
      {:error, %DeliveryError{} = error} -> {:error, DeliveryError.message(error)}
    end
  end

  defp require_recipient(nil) do
    {:error,
     DeliveryError.permanent(
       "no recipient: set activity metadata 'recipient_phone' or 'to', or reply in a conversation with a participant on this channel"
     )}
  end

  defp require_recipient(recipient), do: {:ok, recipient}

  # Re-checked at send time: DNS may have changed since the config was saved,
  # and configs saved before the guard existed were never checked.
  defp check_target(base_url) do
    case UrlGuard.resolve(base_url || "") do
      {:ok, _target} ->
        :ok

      {:error, {:unresolvable, _} = reason} ->
        {:error,
         %DeliveryError{reason: "Infobip base_url rejected: " <> UrlGuard.format_error(reason)}}

      {:error, reason} ->
        {:error,
         DeliveryError.permanent("Infobip base_url rejected: " <> UrlGuard.format_error(reason))}
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
      "idempotency_key" => result["messageId"],
      # Resolved to `reply_to_id` by the inbound controller.
      "reply_to_provider_id" => get_in(message, ["context", "id"]),
      "participant" => %{
        "external_id" => result["from"],
        "display_name" => metadata["profile_name"]
      }
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
        "channelData" =>
          reject_nil_values(%{
            "provider" => "whatsapp_infobip",
            "providerMediaId" => message["id"],
            "providerMediaUrl" => message["url"]
          })
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
