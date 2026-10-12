defmodule Converger.Channels.Meta.Messaging do
  @moduledoc """
  The Messenger Platform shared by the `messenger` and `instagram` adapters:
  both receive `entry[].messaging[]` webhooks and send through the Send API
  (`POST /<version>/<account id>/messages`), with the same message, postback,
  reaction, edit and receipt shapes. Each adapter passes a `t:spec/0` that
  names its provider, Graph host, account id, token and limits.

  See `docs/channels/messenger.md`, `docs/channels/instagram.md` and
  ADR-0048.
  """

  alias Converger.Channels.{ChatContent, DeliveryError}
  alias Converger.Channels.Meta.Graph
  alias Converger.Channels.WhatsApp.Outbound
  alias Converger.{Participants, Uploads}
  alias Converger.Pipeline.RetryPolicy

  @typedoc """
    * `:provider` - `"messenger"` or `"instagram"` (attachment `channelData.provider`,
      metadata keys)
    * `:object` - the webhook `object` (`"page"`, `"instagram"`)
    * `:label` - used in delivery errors (`"Messenger API"`)
    * `:host` - the Graph host of the Send API
    * `:version` - Graph API version
    * `:account_id` - the id the Send API is called on (Page or Instagram account)
    * `:token` - the access token
    * `:req_options_key` - application env key of extra Req options
    * `:upload?` - whether files stored in Converger can be uploaded (Messenger)
    * `:max_text` - maximum characters per text message
  """
  @type spec :: %{
          provider: String.t(),
          object: String.t(),
          label: String.t(),
          host: String.t(),
          version: String.t(),
          account_id: String.t() | nil,
          token: String.t() | nil,
          req_options_key: atom(),
          upload?: boolean(),
          max_text: pos_integer()
        }

  # Send API limits: 13 quick replies, 20 characters per quick-reply title.
  @max_quick_replies 13
  @max_quick_reply_title 20

  # Error 10 with subcode 2018278: the 24-hour standard messaging window is
  # closed and the message has no tag.
  @outside_window_subcode 2_018_278

  @media_defaults %{
    "image" => "image/jpeg",
    "video" => "video/mp4",
    "audio" => "audio/mpeg",
    "file" => "application/octet-stream"
  }

  ## Outbound

  @doc """
  Sends an activity: each file attachment as an attachment message, then the
  text (split at `max_text`), with the card buttons as quick replies on the
  last text message. The provider message id is the `message_id` of the last
  message sent; every id is kept in `meta_message_ids`.
  """
  def deliver(channel, activity, spec) do
    metadata = Map.get(activity, :metadata) || %{}

    recipient =
      metadata["recipient_id"] || Participants.recipient_for(activity, Map.get(channel, :id))

    if is_nil(recipient) do
      {:error,
       DeliveryError.permanent(
         "no recipient: set activity metadata 'recipient_id', or reply in a conversation with a participant on this channel"
       )}
    else
      case build_messages(channel, activity, spec) do
        [] -> {:error, DeliveryError.permanent("nothing to send: no text or media")}
        messages -> send_all(to_string(recipient), messages, messaging_type(metadata), spec)
      end
    end
  end

  defp messaging_type(%{"message_tag" => tag}) when is_binary(tag) and tag != "",
    do: %{"messaging_type" => "MESSAGE_TAG", "tag" => tag}

  defp messaging_type(_metadata), do: %{"messaging_type" => "RESPONSE"}

  defp build_messages(channel, activity, spec) do
    buttons = ChatContent.buttons(activity)
    {quick_replies, links} = Enum.split_with(buttons, &is_nil(&1["url"]))

    link_lines = Enum.map(links, &"#{&1["title"]}: #{&1["url"]}")
    text = Enum.join(Enum.reject([ChatContent.text(activity) | link_lines], &(&1 == "")), "\n")

    media = for a <- ChatContent.media(activity), do: {:media, channel, a}
    texts = for chunk <- ChatContent.split(text, spec.max_text), do: %{"text" => chunk}

    put_quick_replies(media ++ texts, quick_replies)
  end

  defp put_quick_replies(messages, []), do: messages

  defp put_quick_replies(messages, buttons) do
    quick_replies =
      buttons
      |> Enum.take(@max_quick_replies)
      |> Enum.map(fn b ->
        %{
          "content_type" => "text",
          "title" => String.slice(b["title"], 0, @max_quick_reply_title),
          "payload" => b["payload"]
        }
      end)

    case List.last(messages) do
      %{"text" => _} = last ->
        List.replace_at(messages, -1, Map.put(last, "quick_replies", quick_replies))

      # Quick replies need a text message to ride on.
      _ ->
        messages ++ [%{"text" => "Choose an option", "quick_replies" => quick_replies}]
    end
  end

  defp send_all(recipient, messages, messaging, spec) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, ids} ->
      case send_message(recipient, message, messaging, spec) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} ->
        ids = ids |> Enum.reverse() |> Enum.reject(&is_nil/1)

        {:ok,
         %{
           provider_message_id: List.last(ids),
           meta_message_ids: ids
         }}

      {:error, _} = error ->
        error
    end
  end

  defp send_message(recipient, {:media, channel, attachment}, messaging, spec) do
    kind = ChatContent.media_kind(attachment)

    case Outbound.media_source(channel, attachment, spec.provider) do
      {:link, url} ->
        message = %{"attachment" => %{"type" => kind, "payload" => %{"url" => url}}}
        send_message(recipient, message, messaging, spec)

      {:stored, stored} when spec.upload? ->
        upload_message(recipient, kind, stored, messaging, spec)

      {:stored, stored} ->
        {:error,
         DeliveryError.permanent(
           "#{spec.label} cannot fetch Converger attachment #{stored.id}: send media with a public contentUrl"
         )}

      {:provider_id, id} ->
        message = %{"attachment" => %{"type" => kind, "payload" => %{"attachment_id" => id}}}
        send_message(recipient, message, messaging, spec)

      {:error, _} = error ->
        error
    end
  end

  defp send_message(recipient, message, messaging, spec) do
    body = Map.merge(messaging, %{"recipient" => %{"id" => recipient}, "message" => message})
    post(spec, json: body)
  end

  # Messenger accepts the file itself in the Send API call (`filedata`).
  defp upload_message(recipient, kind, stored, messaging, spec) do
    case Uploads.storage().get(Uploads.storage_opts(), stored.storage_key) do
      {:ok, data} ->
        message = %{"attachment" => %{"type" => kind, "payload" => %{"is_reusable" => false}}}

        form =
          Enum.map(messaging, fn {k, v} -> {k, v} end) ++
            [
              {"recipient", Jason.encode!(%{"id" => recipient})},
              {"message", Jason.encode!(message)},
              {"filedata",
               {data, filename: stored.filename || stored.id, content_type: stored.content_type}}
            ]

        post(spec, form_multipart: form)

      {:error, :not_found} ->
        {:error, DeliveryError.permanent("attachment #{stored.id} file is missing")}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, "attachment storage")}
    end
  end

  defp post(spec, body_options) do
    url = Graph.url(spec.host, spec.version, "#{spec.account_id}/messages")

    options =
      Graph.request_options(
        spec.token,
        Keyword.merge([receive_timeout: spec[:timeout_ms] || 15_000], body_options),
        spec.req_options_key
      )

    case Req.post(url, options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, if(is_map(body), do: body["message_id"])}

      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:error, classify(status, headers, body, spec.label)}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, spec.label)}
    end
  end

  @doc """
  Classifies a Send API error: `Converger.Channels.Meta.Graph.classify_http/4`,
  with a readable permanent `outside_window` error when the 24-hour messaging
  window is closed (error 10 / subcode #{@outside_window_subcode}).
  """
  def classify(status, headers, body, label) do
    if Graph.error_subcode(body) == @outside_window_subcode do
      error =
        DeliveryError.permanent(
          "outside_window: the person has not messaged in the last 24 hours; set " <>
            "metadata.message_tag (e.g. HUMAN_AGENT) to send outside the window " <>
            "(#{label} returned #{status})"
        )

      %{error | status: status}
    else
      Graph.classify_http(status, headers, body, label)
    end
  end

  @doc "Timeout of Send API calls from the channel's retry policy."
  def timeout_ms(channel), do: RetryPolicy.for_channel(channel).timeout_ms

  ## Inbound

  @doc """
  Parses a Messenger Platform webhook (`object` must be `spec.object`): every
  `entry[].messaging[]` event that is a message, an edit, an unsend, a
  postback or a reaction becomes one parsed message. Echoes of the account's
  own messages, receipts and other events are skipped.
  """
  def parse_inbound(%{"object" => object, "entry" => entries}, spec)
      when is_list(entries) and object == spec.object do
    {:ok, entries |> events() |> Enum.flat_map(&parse_event(&1, spec))}
  end

  def parse_inbound(_params, spec),
    do: {:error, "unable to parse #{spec.label} webhook payload"}

  defp events(entries) do
    for entry <- entries,
        is_map(entry),
        event <- list(entry["messaging"]),
        is_map(event),
        is_binary(get_in(event, ["sender", "id"])),
        do: event
  end

  defp parse_event(%{"message" => %{"is_echo" => true}}, _spec), do: []

  defp parse_event(%{"message" => %{"is_deleted" => true} = message} = event, spec) do
    [
      base(event, spec)
      |> Map.merge(%{
        "type" => "messageDelete",
        "text" => "",
        "idempotency_key" => "#{message["mid"]}:deleted",
        "reply_to_provider_id" => message["mid"]
      })
    ]
  end

  defp parse_event(%{"message" => %{} = message} = event, spec) do
    {text, attachments} = message_content(message, spec)

    extra =
      reject_nil_values(%{
        "mid" => message["mid"],
        "quick_reply_payload" => get_in(message, ["quick_reply", "payload"]),
        "reply_to" => get_in(message, ["reply_to", "mid"]),
        "story" => get_in(message, ["reply_to", "story"])
      })

    [
      base(event, spec)
      |> Map.merge(%{
        "type" => "message",
        "text" => text,
        "attachments" => attachments,
        "idempotency_key" => message["mid"],
        "reply_to_provider_id" => get_in(message, ["reply_to", "mid"])
      })
      |> merge_metadata(extra)
    ]
  end

  defp parse_event(%{"message_edit" => %{"mid" => mid} = edit} = event, spec) do
    [
      base(event, spec)
      |> Map.merge(%{
        "type" => "messageUpdate",
        "text" => edit["text"] || "",
        "idempotency_key" => "#{mid}:edit:#{edit["num_edit"] || event["timestamp"]}",
        "reply_to_provider_id" => mid
      })
      |> merge_metadata(%{"mid" => mid, "num_edit" => edit["num_edit"]})
    ]
  end

  # A button press (postback) shows in the thread as the button title.
  defp parse_event(%{"postback" => %{} = postback} = event, spec) do
    sender = get_in(event, ["sender", "id"])

    [
      base(event, spec)
      |> Map.merge(%{
        "type" => "message",
        "text" => postback["title"] || postback["payload"] || "",
        "idempotency_key" => postback["mid"] || "postback:#{sender}:#{event["timestamp"]}"
      })
      |> merge_metadata(
        reject_nil_values(%{
          "mid" => postback["mid"],
          "interactive_reply" =>
            reject_nil_values(%{
              "type" => "postback",
              "title" => postback["title"],
              "payload" => postback["payload"]
            })
        })
      )
    ]
  end

  defp parse_event(%{"reaction" => %{"mid" => mid} = reaction} = event, spec) do
    sender = get_in(event, ["sender", "id"])
    emoji = if reaction["action"] == "unreact", do: "", else: reaction["emoji"] || ""

    [
      base(event, spec)
      |> Map.merge(%{
        "type" => "messageReaction",
        "text" => emoji,
        "idempotency_key" =>
          "reaction:#{mid}:#{sender}:#{reaction["action"]}:#{event["timestamp"]}",
        "reply_to_provider_id" => mid
      })
      |> merge_metadata(%{
        "reaction" =>
          reject_nil_values(%{
            "message_id" => mid,
            "action" => reaction["action"],
            "emoji" => reaction["emoji"],
            "reaction" => reaction["reaction"]
          })
      })
    ]
  end

  defp parse_event(_event, _spec), do: []

  defp base(event, spec) do
    sender = get_in(event, ["sender", "id"])

    %{
      "sender" => sender,
      "attachments" => [],
      "metadata" =>
        reject_nil_values(%{
          "#{spec.provider}_recipient_id" => get_in(event, ["recipient", "id"]),
          "timestamp" => event["timestamp"]
        }),
      "participant" => %{"external_id" => sender}
    }
  end

  defp merge_metadata(message, extra),
    do: Map.update!(message, "metadata", &Map.merge(&1, reject_nil_values(extra)))

  defp message_content(message, spec) do
    {texts, attachments} =
      message
      |> Map.get("attachments")
      |> list()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&attachment(&1, spec))
      |> Enum.unzip()

    text =
      [message["text"] | texts]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    {text, Enum.reject(attachments, &is_nil/1)}
  end

  # Returns {text_or_nil, attachment_or_nil}.
  defp attachment(%{"type" => "location", "payload" => payload}, _spec) do
    coordinates = get_in(payload, ["coordinates"]) || %{}

    content =
      reject_nil_values(%{
        "latitude" => coordinates["lat"],
        "longitude" => coordinates["long"],
        "name" => payload["title"]
      })

    {nil, %{"contentType" => "application/vnd.converger.location", "content" => content}}
  end

  # A shared link: no file, the URL becomes part of the text.
  defp attachment(%{"type" => "fallback", "payload" => payload}, _spec),
    do: {payload["url"] || payload["title"], nil}

  defp attachment(%{"type" => type, "payload" => %{"url" => url} = payload}, spec)
       when is_binary(url) do
    attachment =
      reject_nil_values(%{
        "contentType" => Map.get(@media_defaults, type, "application/octet-stream"),
        "name" => payload["title"],
        "channelData" =>
          reject_nil_values(%{
            "provider" => spec.provider,
            "kind" => type,
            "providerMediaUrl" => url,
            "stickerId" => payload["sticker_id"]
          })
      })

    {nil, attachment}
  end

  defp attachment(%{"type" => type} = raw, spec) do
    {nil,
     %{
       "contentType" => "application/vnd.converger.#{spec.provider}.#{safe_type(type)}",
       "content" => raw
     }}
  end

  defp attachment(_raw, _spec), do: {nil, nil}

  defp safe_type(type) when is_binary(type) do
    if Regex.match?(~r/\A[a-z0-9_]{1,40}\z/, type), do: type, else: "unknown"
  end

  defp safe_type(_type), do: "unknown"

  @doc """
  Delivery and read receipts of a Messenger Platform webhook: `delivery.mids`
  become `delivered` updates and `read.mid` (Instagram) a `read` update. A
  Messenger read receipt carries only a `watermark` timestamp, which names
  no message, and is ignored.
  """
  def parse_status_update(%{"object" => object, "entry" => entries}, spec)
      when is_list(entries) and object == spec.object do
    updates =
      Enum.flat_map(events(entries), fn event ->
        recipient = get_in(event, ["sender", "id"])
        timestamp = event["timestamp"]

        delivered =
          for mid <- list(get_in(event, ["delivery", "mids"])), is_binary(mid) do
            status_update(mid, "delivered", recipient, timestamp)
          end

        read =
          case get_in(event, ["read", "mid"]) do
            mid when is_binary(mid) -> [status_update(mid, "read", recipient, timestamp)]
            _ -> []
          end

        delivered ++ read
      end)

    if updates == [], do: :ignore, else: {:ok, updates}
  end

  def parse_status_update(_params, _spec), do: :ignore

  # Messenger Platform timestamps are Unix milliseconds; receipts take seconds.
  defp status_update(mid, status, recipient, timestamp) do
    reject_nil_values(%{
      "provider_message_id" => mid,
      "status" => status,
      "recipient_id" => recipient,
      "timestamp" => if(is_integer(timestamp), do: div(timestamp, 1000))
    })
  end

  @doc """
  Downloads an inbound attachment from its CDN URL
  (`channelData.providerMediaUrl`); see
  `Converger.Channels.Meta.Graph.fetch_media_url/2`.
  """
  def fetch_media(%{"channelData" => %{"providerMediaUrl" => url}}, spec)
      when is_binary(url) and url != "",
      do: Graph.fetch_media_url(url, spec.req_options_key)

  def fetch_media(_attachment, _spec), do: :skip

  @doc "Reads the account (`GET /<version>/<account id>?fields=id`) with the token."
  def health_probe(spec) do
    url = Graph.url(spec.host, spec.version, to_string(spec.account_id))

    options =
      Graph.request_options(
        spec.token,
        [params: [fields: "id"], receive_timeout: 5_000, retry: false],
        spec.req_options_key
      )

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "#{spec.label} returned #{status}"}
      {:error, reason} -> {:error, "#{spec.label} request failed: #{inspect(reason)}"}
    end
  end

  defp list(value) when is_list(value), do: value
  defp list(_), do: []

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
