defmodule Converger.Channels.Adapters.Viber do
  @moduledoc """
  Viber bot channel adapter (duplex), on the Viber REST Bot API.

    * Inbound: Viber callbacks on `POST /api/v1/channels/:id/inbound`, signed
      with `X-Viber-Content-Signature` (hex HMAC-SHA256 of the body, keyed
      with the bot's auth token). Registered with `set_webhook`
      (`register_webhook/2`).
    * Outbound: `POST /pa/send_message`: text (card buttons become a Viber
      keyboard), pictures, videos, files, locations and contacts.
    * Receipts: `delivered`, `seen` and `failed` callbacks.
    * Opt-out: `unsubscribed` marks the participant opted out and
      `subscribed` opts it in again.

  See `docs/channels/viber.md`.
  """

  use Converger.Channels.Adapter, type: "viber"

  alias Converger.Channels.{ChatContent, DeliveryError, InboundSignature, MediaDownload}
  alias Converger.Channels.WhatsApp.Outbound
  alias Converger.Participants
  alias Converger.Pipeline.RetryPolicy

  @default_api_base_url "https://chatapi.viber.com/pa"

  # Viber limits: text 7000 characters, sender name 28, picture caption 768.
  @max_text 7000
  @max_sender_name 28
  @max_caption 768

  @event_types ~w(delivered seen failed subscribed unsubscribed conversation_started)

  # send_message status codes: 12 is "too many requests"; every other
  # documented code (1-24) is a request, account or recipient problem that a
  # retry cannot fix. Unknown codes are Viber's "general error": retried.
  @retryable_status 12
  @permanent_statuses Enum.to_list(1..24) -- [@retryable_status]

  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :receipts,
      :provider_ack,
      :media,
      activity_types: ~w(message)
    ]
  end

  @impl true
  def config_schema do
    [
      %{
        name: "auth_token",
        type: :string,
        required: true,
        secret: true,
        label: "Auth Token",
        placeholder: "From the Viber Admin Panel; also signs callbacks"
      },
      %{
        name: "sender_name",
        type: :string,
        required: true,
        label: "Sender name",
        placeholder: "Shown as the message sender (max 28 characters)",
        summary: true
      },
      %{
        name: "sender_avatar",
        type: :url,
        label: "Sender avatar URL",
        placeholder: "https://example.com/avatar.jpg"
      },
      %{
        name: "download_media",
        type: :boolean,
        label: "Download inbound media",
        help: "Store inbound pictures, videos and files in Converger (default true)"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    if String.length(to_string(config["sender_name"])) > @max_sender_name,
      do: {:error, "viber config 'sender_name' must be at most #{@max_sender_name} characters"},
      else: :ok
  end

  ## Outbound

  @doc """
  Sends an activity: each file attachment as a picture (JPEG, PNG, GIF),
  video or file message (or a URL message when its size is unknown), each
  location and contact natively, then the text; the card buttons become a
  keyboard on the last message. The provider message id is the
  `message_token` of the last message sent.
  """
  @impl true
  def deliver_activity(channel, activity) do
    metadata = Map.get(activity, :metadata) || %{}

    recipient =
      metadata["recipient_id"] || Participants.recipient_for(activity, Map.get(channel, :id))

    if is_nil(recipient) do
      {:error,
       DeliveryError.permanent(
         "no recipient: set activity metadata 'recipient_id', or reply in a conversation with a participant on this channel"
       )}
    else
      with {:ok, messages} <- build_messages(channel, activity) do
        case messages do
          [] -> {:error, DeliveryError.permanent("nothing to send: no text or media")}
          messages -> send_all(channel, to_string(recipient), messages)
        end
      end
    end
  end

  defp build_messages(channel, activity) do
    buttons = ChatContent.buttons(activity)
    attachments = List.wrap(Map.get(activity, :attachments))

    with {:ok, media} <- media_messages(channel, ChatContent.media(activity)) do
      native = Enum.flat_map(attachments, &native_message/1)

      text =
        activity
        |> Map.put(:attachments, Enum.reject(attachments, &native?/1))
        |> ChatContent.text()

      texts =
        for chunk <- ChatContent.split(text, @max_text), do: %{"type" => "text", "text" => chunk}

      {:ok, put_keyboard(media ++ native ++ texts, buttons)}
    end
  end

  defp media_messages(channel, attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      case Outbound.media_source(channel, attachment, "viber") do
        {:link, url} ->
          {:cont, {:ok, acc ++ [media_message(attachment, url)]}}

        {:provider_id, _id} ->
          {:cont, {:ok, acc}}

        {:stored, stored} ->
          {:halt,
           {:error,
            DeliveryError.permanent(
              "Viber cannot fetch Converger attachment #{stored.id}: send media with a public contentUrl"
            )}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp media_message(%{"contentType" => type} = attachment, url)
       when type in ["image/jpeg", "image/png", "image/gif"] do
    put_present(%{"type" => "picture", "media" => url, "text" => ""}, "text", caption(attachment))
  end

  defp media_message(attachment, url) do
    size = attachment["size"]

    cond do
      not (is_integer(size) and size > 0) ->
        %{"type" => "url", "media" => url}

      ChatContent.media_kind(attachment) == "video" ->
        %{"type" => "video", "media" => url, "size" => size}

      true ->
        %{
          "type" => "file",
          "media" => url,
          "size" => size,
          "file_name" =>
            attachment["name"] || url |> URI.parse() |> Map.get(:path, "") |> Path.basename()
        }
    end
  end

  defp caption(%{"name" => name}) when is_binary(name) and name != "",
    do: String.slice(name, 0, @max_caption)

  defp caption(_attachment), do: nil

  @location_type "application/vnd.converger.location"
  @contacts_type "application/vnd.converger.contacts"

  defp native?(%{"contentType" => type}) when type in [@location_type, @contacts_type], do: true
  defp native?(_attachment), do: false

  defp native_message(%{"contentType" => @location_type, "content" => %{} = location}) do
    if is_number(location["latitude"]) and is_number(location["longitude"]),
      do: [
        %{
          "type" => "location",
          "location" => %{"lat" => location["latitude"], "lon" => location["longitude"]}
        }
      ],
      else: []
  end

  defp native_message(%{"contentType" => @contacts_type, "content" => contacts})
       when is_list(contacts) do
    for contact <- contacts,
        is_map(contact),
        phone = Enum.find(List.wrap(contact["phones"]), &is_binary/1),
        do: %{
          "type" => "contact",
          "contact" => %{"name" => contact["name"] || phone, "phone_number" => phone}
        }
  end

  defp native_message(_attachment), do: []

  # A Viber keyboard on the last message: one full-width button per row.
  defp put_keyboard([], _buttons), do: []
  defp put_keyboard(messages, []), do: messages

  defp put_keyboard(messages, buttons) do
    keyboard = %{
      "Type" => "keyboard",
      "DefaultHeight" => false,
      "Buttons" =>
        Enum.map(buttons, fn button ->
          if button["url"],
            do: %{
              "ActionType" => "open-url",
              "ActionBody" => button["url"],
              "Text" => button["title"]
            },
            else: %{
              "ActionType" => "reply",
              "ActionBody" => button["payload"],
              "Text" => button["title"]
            }
        end)
    }

    List.update_at(messages, -1, &Map.put(&1, "keyboard", keyboard))
  end

  defp send_all(channel, recipient, messages) do
    config = channel.config || %{}

    sender =
      put_present(
        %{"name" => String.slice(to_string(config["sender_name"]), 0, @max_sender_name)},
        "avatar",
        config["sender_avatar"]
      )

    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, tokens} ->
      body = Map.merge(message, %{"receiver" => recipient, "sender" => sender})

      case call(channel, "send_message", body,
             receive_timeout: RetryPolicy.for_channel(channel).timeout_ms
           ) do
        {:ok, response} -> {:cont, {:ok, [token(response["message_token"]) | tokens]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tokens} ->
        tokens = tokens |> Enum.reverse() |> Enum.reject(&is_nil/1)
        {:ok, %{provider_message_id: List.last(tokens), viber_message_tokens: tokens}}

      {:error, _} = error ->
        error
    end
  end

  defp token(nil), do: nil
  defp token(value), do: to_string(value)

  @doc """
  Calls a Viber Bot API method (`POST <api base>/<method>` with the
  `X-Viber-Auth-Token` header). Viber answers `200` with a `status` in the
  body: `0` is `{:ok, body}`; anything else is `{:error, %DeliveryError{}}`,
  retryable for status #{@retryable_status} (too many requests) and unknown
  statuses, permanent for the documented request, account and recipient
  errors.
  """
  def call(channel, method, body, opts \\ []) do
    url = "#{api_base_url()}/#{method}"

    options =
      [
        json: body,
        headers: [{"x-viber-auth-token", (channel.config || %{})["auth_token"]}]
      ]
      |> Keyword.merge(opts)
      |> Keyword.merge(Application.get_env(:converger, :viber_req_options, []))

    case Req.post(url, options) do
      {:ok, %Req.Response{status: 200, body: %{"status" => 0} = response}} ->
        {:ok, response}

      {:ok, %Req.Response{status: 200, body: %{"status" => status} = response}} ->
        {:error, status_error(status, response, method)}

      {:ok, %Req.Response{status: status, headers: headers, body: response}} ->
        {:error, DeliveryError.from_http(status, headers, response, "Viber #{method}")}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, "Viber #{method}")}
    end
  end

  defp status_error(status, response, method) do
    reason =
      "Viber #{method} failed with status #{status}: #{response["status_message"] || "unknown"}"

    if status in @permanent_statuses,
      do: DeliveryError.permanent(reason),
      else: %DeliveryError{reason: reason, retryable?: true}
  end

  @doc """
  Viber API base URL: `config :converger, #{inspect(__MODULE__)}, api_base_url:
  "..."`, else #{@default_api_base_url}. An operator setting only: the URL
  receives the auth token.
  """
  def api_base_url do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:api_base_url, @default_api_base_url)
    |> String.trim_trailing("/")
  end

  @doc "Reads the bot account (`get_account_info`)."
  @impl true
  def health_probe(channel) do
    case call(channel, "get_account_info", %{}, receive_timeout: 5_000, retry: false) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, DeliveryError.message(error)}
    end
  end

  @doc """
  Points the bot's webhook at `inbound_url` (`set_webhook`) with the
  delivered, seen, failed, subscribed, unsubscribed and conversation_started
  events. Viber checks the URL with a signed `webhook` callback before it
  answers.
  """
  @impl true
  def register_webhook(channel, inbound_url) do
    body = %{
      "url" => inbound_url,
      "event_types" => @event_types,
      "send_name" => true,
      "send_photo" => true
    }

    case call(channel, "set_webhook", body, receive_timeout: 15_000, retry: false) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, DeliveryError.message(error)}
    end
  end

  ## Inbound

  @doc """
  Verifies `X-Viber-Content-Signature`: the hex HMAC-SHA256 of the raw body,
  keyed with the channel's `auth_token`. Viber signs every callback, so a
  missing header is rejected too.
  """
  @impl true
  def verify_inbound_signature(channel, headers, raw_body) do
    token = (channel.config || %{})["auth_token"]

    case InboundSignature.get_header(headers, "x-viber-content-signature") do
      _signature when not is_binary(token) or token == "" ->
        :missing

      nil ->
        {:error, :missing_signature}

      signature ->
        expected = InboundSignature.hmac_hex(token, raw_body || "")

        if Plug.Crypto.secure_compare(expected, String.downcase(signature)),
          do: :ok,
          else: {:error, :invalid_signature}
    end
  end

  @doc """
  Parses one Viber callback: `message` becomes a message (media as
  attachments downloaded into Converger), `conversation_started`,
  `subscribed` and `unsubscribed` become events (the last two opt the
  participant in and out). `webhook` and receipts carry no message.
  """
  @impl true
  def parse_inbound(_channel, %{"event" => "message", "message" => %{} = message} = callback) do
    sender = callback["sender"] || %{}
    {text, attachments} = content(message)

    {:ok,
     [
       %{
         "sender" => sender["id"],
         "type" => "message",
         "text" => text,
         "attachments" => attachments,
         "metadata" =>
           reject_nil_values(%{
             "viber_message_token" => token(callback["message_token"]),
             "viber_type" => message["type"],
             "timestamp" => callback["timestamp"],
             "language" => sender["language"],
             "country" => sender["country"],
             "tracking_data" => message["tracking_data"]
           }),
         "idempotency_key" => token(callback["message_token"]),
         "participant" => participant(sender)
       }
     ]}
  end

  def parse_inbound(_channel, %{"event" => event} = callback)
      when event in ~w(conversation_started subscribed unsubscribed) do
    user = callback["user"] || %{"id" => callback["user_id"]}

    message =
      %{
        "sender" => user["id"],
        "type" => "event",
        "text" => "",
        "attachments" => [],
        "metadata" =>
          reject_nil_values(%{
            "name" => "viber.#{event}",
            "viber_message_token" => token(callback["message_token"]),
            "timestamp" => callback["timestamp"],
            "context" => callback["context"],
            "subscribed" => callback["subscribed"]
          }),
        "idempotency_key" =>
          "#{event}:#{token(callback["message_token"]) || "#{user["id"]}:#{callback["timestamp"]}"}",
        "participant" => participant(user)
      }
      |> put_opt_out(event)

    if is_binary(user["id"]),
      do: {:ok, [message]},
      else: {:error, "Viber #{event} without a user"}
  end

  def parse_inbound(_channel, %{"event" => event}) when is_binary(event), do: {:ok, []}

  def parse_inbound(_channel, _params), do: {:error, "unable to parse Viber callback"}

  # Picked up by Converger.Inbound: the participant flag is set before the
  # event is stored (as for SMS STOP / START).
  defp put_opt_out(message, "unsubscribed"), do: Map.put(message, "opt_out", "stop")
  defp put_opt_out(message, "subscribed"), do: Map.put(message, "opt_out", "start")
  defp put_opt_out(message, _event), do: message

  defp participant(user) do
    reject_nil_values(%{"external_id" => user["id"], "display_name" => user["name"]})
  end

  @media_types %{
    "picture" => "image/jpeg",
    "video" => "video/mp4",
    "file" => "application/octet-stream",
    "sticker" => "image/png"
  }

  # Returns {text, attachments}.
  defp content(%{"type" => type, "media" => url} = message)
       when is_map_key(@media_types, type) and is_binary(url) do
    attachment =
      reject_nil_values(%{
        "contentType" => Map.fetch!(@media_types, type),
        "name" => message["file_name"],
        "size" => message["size"],
        "channelData" =>
          reject_nil_values(%{
            "provider" => "viber",
            "kind" => type,
            "providerMediaUrl" => url,
            "stickerId" => message["sticker_id"],
            "duration" => message["duration"]
          })
      })

    {message["text"] || "", [attachment]}
  end

  defp content(%{"type" => "location", "location" => %{} = location} = message) do
    content =
      reject_nil_values(%{
        "latitude" => location["lat"],
        "longitude" => location["lon"],
        "address" => location["address"]
      })

    {message["text"] || location["address"] || "",
     [%{"contentType" => "application/vnd.converger.location", "content" => content}]}
  end

  defp content(%{"type" => "contact", "contact" => %{} = contact}) do
    contacts = [
      reject_nil_values(%{"name" => contact["name"], "phones" => [contact["phone_number"]]})
    ]

    {contact["name"] || "",
     [%{"contentType" => "application/vnd.converger.contacts", "content" => contacts}]}
  end

  defp content(%{"type" => "url", "media" => url}), do: {url, []}
  defp content(message), do: {message["text"] || "", []}

  @doc """
  `delivered`, `seen` (read) and `failed` callbacks, matched by the
  `message_token` Viber returned for the message.
  """
  @impl true
  def parse_status_update(_channel, %{"event" => event, "message_token" => message_token} = cb)
      when event in ~w(delivered seen failed) do
    {:ok,
     [
       reject_nil_values(%{
         "provider_message_id" => token(message_token),
         "status" => normalize_status(event),
         "recipient_id" => cb["user_id"],
         "timestamp" => if(is_integer(cb["timestamp"]), do: div(cb["timestamp"], 1000)),
         "error" => if(event == "failed", do: cb["desc"] || "failed")
       })
     ]}
  end

  def parse_status_update(_channel, _params), do: :ignore

  defp normalize_status("delivered"), do: "delivered"
  defp normalize_status("seen"), do: "read"
  defp normalize_status("failed"), do: "failed"

  @doc "Downloads an inbound picture, video or file from Viber's media URL."
  @impl true
  def fetch_media(_channel, %{"channelData" => %{"providerMediaUrl" => url}})
      when is_binary(url) and url != "",
      do: MediaDownload.get_public(url, :viber_req_options)

  def fetch_media(_channel, _attachment), do: :skip

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
