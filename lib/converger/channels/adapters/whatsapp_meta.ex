defmodule Converger.Channels.Adapters.WhatsAppMeta do
  use Converger.Channels.Adapter, type: "whatsapp_meta"

  alias Converger.Channels.{DeliveryError, InboundSignature, MediaDownload}
  alias Converger.Channels.WhatsApp.Outbound
  alias Converger.{Participants, Uploads}
  alias Converger.Pipeline.RetryPolicy

  require Logger

  # Latest Graph API version as of 2026-07-29 (v26.0); override per channel
  # with `graph_api_version` or globally in config.
  @default_graph_api_version "v26.0"

  # `message` activities are sent as text, media, template, interactive,
  # location and contacts messages (Converger.Channels.WhatsApp.Outbound).
  # Native outbound reactions and edits are not implemented; other activity
  # types are downgraded to text or skipped (Converger.Activities.Downgrade).
  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :receipts,
      :typing,
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
        name: "phone_number_id",
        type: :string,
        required: true,
        label: "Phone Number ID",
        placeholder: "e.g. 1234567890",
        summary: true
      },
      %{
        name: "access_token",
        type: :string,
        required: true,
        secret: true,
        label: "Access Token",
        placeholder: "Graph API access token"
      },
      %{
        name: "verify_token",
        type: :string,
        required: true,
        secret: true,
        label: "Verify Token",
        placeholder: "Webhook verify token"
      },
      # Meta signs webhooks with the app secret, so a channel that requires
      # signatures cannot accept anything without it.
      %{
        name: "app_secret",
        type: :string,
        required: :with_signature,
        secret: true,
        label: "App Secret",
        placeholder: "Signs X-Hub-Signature-256"
      },
      %{
        name: "graph_api_version",
        type: :string,
        label: "Graph API version",
        placeholder: @default_graph_api_version
      },
      %{
        name: "waba_id",
        type: :string,
        label: "WhatsApp Business Account ID",
        placeholder: "Needed to list templates",
        help: "Used by GET /api/v1/channels/:id/templates"
      },
      %{
        name: "download_media",
        type: :boolean,
        label: "Download inbound media",
        help: "Store inbound images, audio and documents in Converger (default true)"
      }
    ]
  end

  # Cloud API default throughput per business phone number (80 messages/s);
  # higher-throughput numbers override it with the channel's `rate_limit`.
  @impl true
  def rate_limit, do: "80/s"

  @impl true
  def deliver_activity(channel, activity) do
    recipient =
      activity.metadata["recipient_phone"] || activity.metadata["to"] ||
        Participants.recipient_for(activity, Map.get(channel, :id))

    if is_nil(recipient) do
      {:error,
       DeliveryError.permanent(
         "no recipient: set activity metadata 'recipient_phone' or 'to', or reply in a conversation with a participant on this channel"
       )}
    else
      with {:ok, parts} <- Outbound.parts(activity) do
        send_parts(channel, recipient, parts)
      end
    end
  end

  # One WhatsApp message per part, in order. The first message id is the
  # delivery's provider_message_id (receipts are matched against it); every
  # id is kept in whatsapp_message_ids. A failure after the first part makes
  # the retry send the earlier parts again (at-least-once).
  defp send_parts(channel, recipient, parts) do
    result =
      Enum.reduce_while(parts, [], fn part, ids ->
        with {:ok, content} <- render(channel, part),
             {:ok, id} <- post_message(channel, recipient, content) do
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

        {:ok,
         %{whatsapp_message_id: first, provider_message_id: first, whatsapp_message_ids: ids}}
    end
  end

  # The message body of a part, without the envelope (messaging_product, to).
  defp render(_channel, {:text, text}), do: {:ok, %{type: "text", text: %{body: text}}}

  defp render(_channel, {:template, template}) do
    {:ok,
     %{
       type: "template",
       template: %{
         name: template["name"],
         language: %{code: template["language"]},
         components: template["components"]
       }
     }}
  end

  defp render(channel, {:media, kind, attachment, caption}) do
    with {:ok, source} <- media_reference(channel, attachment) do
      media =
        source
        |> put_present(:caption, caption)
        |> put_present(:filename, if(kind == "document", do: attachment["name"]))

      {:ok, %{"type" => kind, kind => media}}
    end
  end

  defp render(_channel, {:location, content}) do
    location =
      %{latitude: content["latitude"], longitude: content["longitude"]}
      |> put_present(:name, content["name"])
      |> put_present(:address, content["address"])

    {:ok, %{type: "location", location: location}}
  end

  defp render(_channel, {:contacts, contacts}) do
    contacts =
      for contact <- contacts do
        name = contact["name"] || "Contact"
        phones = for phone <- List.wrap(contact["phones"]), is_binary(phone), do: %{phone: phone}
        %{name: %{formatted_name: name, first_name: name}, phones: phones}
      end

    {:ok, %{type: "contacts", contacts: contacts}}
  end

  defp render(_channel, {:buttons, card}) do
    buttons =
      for b <- card["buttons"], do: %{type: "reply", reply: %{id: b["id"], title: b["title"]}}

    {:ok, %{type: "interactive", interactive: interactive("button", card, %{buttons: buttons})}}
  end

  defp render(_channel, {:list, card}) do
    sections =
      for s <- card["sections"] do
        rows =
          for r <- s["rows"],
              do: put_present(%{id: r["id"], title: r["title"]}, :description, r["description"])

        put_present(%{rows: rows}, :title, s["title"])
      end

    action = %{button: card["button"], sections: sections}
    {:ok, %{type: "interactive", interactive: interactive("list", card, action)}}
  end

  defp interactive(type, card, action) do
    %{type: type, body: %{text: card["body"]}, action: action}
    |> put_present(:header, card["header"] && %{type: "text", text: card["header"]})
    |> put_present(:footer, card["footer"] && %{text: card["footer"]})
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # A file uploaded to Converger goes to the Media API first: the Graph API
  # cannot fetch Converger's authenticated attachment URL.
  defp media_reference(channel, attachment) do
    case Outbound.media_source(channel, attachment, type()) do
      {:stored, stored} -> upload_media(channel, stored)
      {:provider_id, id} -> {:ok, %{id: id}}
      {:link, url} -> {:ok, %{link: url}}
      {:error, _} = error -> error
    end
  end

  defp upload_media(channel, stored) do
    with {:ok, data} <- read_stored(stored) do
      url = graph_url(channel, "#{channel.config["phone_number_id"]}/media")

      form = [
        messaging_product: "whatsapp",
        type: stored.content_type,
        file: {data, filename: stored.filename || stored.id, content_type: stored.content_type}
      ]

      case Req.post(url, request_options(channel, form_multipart: form)) do
        {:ok, %Req.Response{status: 200, body: %{"id" => id}}} ->
          {:ok, %{id: id}}

        {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
          {:error, classify_http(status, headers, body, "WhatsApp media upload")}

        {:error, reason} ->
          {:error, DeliveryError.from_transport(reason, "WhatsApp media upload")}
      end
    end
  end

  defp read_stored(stored) do
    case Uploads.storage().get(Uploads.storage_opts(), stored.storage_key) do
      {:ok, data} ->
        {:ok, data}

      {:error, :not_found} ->
        {:error, DeliveryError.permanent("attachment #{stored.id} file is missing")}

      {:error, reason} ->
        {:error, %DeliveryError{reason: "attachment storage failed: #{inspect(reason)}"}}
    end
  end

  defp post_message(channel, recipient, content) do
    url = graph_url(channel, "#{channel.config["phone_number_id"]}/messages")

    payload =
      Map.merge(
        %{"messaging_product" => "whatsapp", "recipient_type" => "individual", "to" => recipient},
        Map.new(content, fn {k, v} -> {to_string(k), v} end)
      )

    case Req.post(url, request_options(channel, json: payload)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, get_in(body, ["messages", Access.at(0), "id"])}

      # 400 (e.g. invalid recipient) and auth errors are permanent; 429 and
      # 5xx are retried, honouring Retry-After.
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:error, classify_http(status, headers, body, "WhatsApp API")}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, "WhatsApp API")}
    end
  end

  # Cloud API error 131047 ("Re-engagement message"): more than 24 hours
  # since the customer last wrote, so only templates are accepted.
  @outside_window_code 131_047

  defp classify_http(status, headers, body, label) do
    if error_code(body) == @outside_window_code do
      error =
        DeliveryError.permanent(Outbound.outside_window_message("#{label} returned #{status}"))

      %{error | status: status}
    else
      DeliveryError.from_http(status, headers, body, label)
    end
  end

  defp error_code(%{"error" => %{"code" => code}}), do: code
  defp error_code(_body), do: nil

  defp request_options(channel, options) do
    [
      headers: [{"authorization", "Bearer #{channel.config["access_token"]}"}],
      receive_timeout: RetryPolicy.for_channel(channel).timeout_ms
    ]
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:converger, :whatsapp_req_options, []))
  end

  defp graph_url(channel, path),
    do: "https://graph.facebook.com/#{graph_api_version(channel)}/#{path}"

  @doc """
  Downloads an inbound media file: `GET /<version>/<media id>` returns a
  short-lived URL and the file size (checked against the upload limit), and
  the URL is fetched with the same access token.
  """
  @impl true
  def fetch_media(channel, %{"channelData" => %{"providerMediaId" => media_id}})
      when is_binary(media_id) and media_id != "" do
    url = graph_url(channel, URI.encode(media_id, &URI.char_unreserved?/1))
    options = [receive_timeout: MediaDownload.timeout_ms(), retry: false]

    case Req.get(url, request_options(channel, options)) do
      {:ok, %Req.Response{status: 200, body: %{"url" => media_url} = media}} ->
        if is_integer(media["file_size"]) and media["file_size"] > Uploads.max_file_size() do
          {:error, :too_large}
        else
          headers = [{"authorization", "Bearer #{channel.config["access_token"]}"}]

          with {:ok, data} <- MediaDownload.get(media_url, headers: headers) do
            {:ok, %{data: data, filename: nil}}
          end
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fetch_media(_channel, _attachment), do: :skip

  @max_template_pages 10

  @doc """
  Lists the message templates of the channel's WhatsApp Business Account
  (`GET /<version>/<waba_id>/message_templates`, following `paging.next`
  for up to #{@max_template_pages} pages of 100). Needs the `waba_id`
  config key.
  """
  @impl true
  def list_templates(channel) do
    case channel.config["waba_id"] do
      waba_id when is_binary(waba_id) and waba_id != "" ->
        url = graph_url(channel, "#{waba_id}/message_templates")
        params = [limit: 100, fields: "name,language,status,category,components"]
        fetch_template_pages(channel, url, [params: params], [], @max_template_pages)

      _ ->
        {:error,
         {:invalid_config,
          "whatsapp_meta config 'waba_id' (WhatsApp Business Account id) is required to list templates"}}
    end
  end

  defp fetch_template_pages(_channel, _url, _options, acc, 0), do: {:ok, acc}

  defp fetch_template_pages(channel, url, options, acc, pages_left) do
    options = Keyword.merge(options, retry: false, receive_timeout: 10_000)

    case Req.get(url, request_options(channel, options)) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data} = body}} when is_list(data) ->
        templates =
          acc ++
            for(
              t <- data,
              is_map(t),
              do: Map.take(t, ~w(id name language status category components))
            )

        case get_in(body, ["paging", "next"]) do
          next when is_binary(next) ->
            fetch_template_pages(channel, next, [], templates, pages_left - 1)

          _ ->
            {:ok, templates}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "WhatsApp API returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "WhatsApp API request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Shows the WhatsApp typing indicator to the participant. The Cloud API
  attaches it to the participant's latest inbound message, which it also
  marks as read, and clears it after 25 s or when the next message is sent;
  `isTyping: false` therefore needs no call. Without an inbound message to
  attach to there is nothing to do.
  """
  @impl true
  def send_typing(channel, %{is_typing: true, provider_message_id: message_id})
      when is_binary(message_id) do
    post_status(channel, %{
      messaging_product: "whatsapp",
      status: "read",
      message_id: message_id,
      typing_indicator: %{type: "text"}
    })
  end

  def send_typing(_channel, _signal), do: :ok

  @doc """
  Marks the participant's messages up to `provider_message_id` as read (blue
  ticks): the Cloud API marks that message and every earlier one.
  """
  @impl true
  def send_read_receipt(channel, %{provider_message_id: message_id})
      when is_binary(message_id) do
    post_status(channel, %{messaging_product: "whatsapp", status: "read", message_id: message_id})
  end

  def send_read_receipt(_channel, _signal), do: :ok

  defp post_status(channel, payload) do
    url =
      "https://graph.facebook.com/#{graph_api_version(channel)}/#{channel.config["phone_number_id"]}/messages"

    options =
      [
        json: payload,
        headers: [{"authorization", "Bearer #{channel.config["access_token"]}"}],
        receive_timeout: RetryPolicy.for_channel(channel).timeout_ms,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:converger, :whatsapp_req_options, []))

    case Req.post(url, options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
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
      # Resolved to `reply_to_id` by the inbound controller: the wamid a
      # reaction targets, or the message this one replies to.
      "reply_to_provider_id" => reply_to_provider_id(type, message),
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
        "channelData" =>
          reject_nil_values(%{
            "provider" => "whatsapp_meta",
            "providerMediaId" => media["id"],
            "sha256" => media["sha256"],
            "voice" => media["voice"],
            "animated" => media["animated"]
          })
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

  # A reaction becomes a messageReaction whose `text` is the emoji (empty when
  # the user removed it); the inbound controller resolves `reaction.message_id`
  # to the reacted-to activity and falls back to an `event` when it is unknown.
  defp parse_content("reaction", message) do
    reaction = message["reaction"] || %{}

    {"messageReaction", reaction["emoji"] || "", [],
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

  defp reply_to_provider_id("reaction", message), do: get_in(message, ["reaction", "message_id"])
  defp reply_to_provider_id(_type, message), do: get_in(message, ["context", "id"])

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

  @doc """
  Meta's webhook handshake: echo `hub.challenge` verbatim once
  `hub.verify_token` matches the channel's `verify_token`.
  """
  @impl true
  def verify_subscription(channel, params) do
    verify_token = (channel.config || %{})["verify_token"]
    provided = params["hub.verify_token"]

    if is_binary(verify_token) and verify_token != "" and is_binary(provided) and
         Plug.Crypto.secure_compare(provided, verify_token),
       do: {:ok, params["hub.challenge"] || ""},
       else: :error
  end

  @doc """
  Reads the channel's phone number from the Graph API
  (`GET /<version>/<phone_number_id>?fields=id`): checks that the access
  token is valid and can reach the number.
  """
  @impl true
  def health_probe(channel) do
    url =
      "https://graph.facebook.com/#{graph_api_version(channel)}/#{channel.config["phone_number_id"]}"

    options =
      [
        params: [fields: "id"],
        headers: [{"authorization", "Bearer #{channel.config["access_token"]}"}],
        receive_timeout: 5_000,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:converger, :whatsapp_req_options, []))

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "WhatsApp API returned #{status}"}
      {:error, reason} -> {:error, "WhatsApp API request failed: #{inspect(reason)}"}
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

  # A free-form message sent outside the 24-hour window is accepted with 200
  # and then fails with error 131047 in a status webhook.
  defp extract_error(%{"errors" => [%{"code" => @outside_window_code} = error | _]}),
    do: Outbound.outside_window_message(error["title"] || "error #{@outside_window_code}")

  defp extract_error(%{"errors" => [%{"title" => title} | _]}), do: title
  defp extract_error(_), do: nil
end
