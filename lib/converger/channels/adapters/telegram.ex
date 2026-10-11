defmodule Converger.Channels.Adapters.Telegram do
  @moduledoc """
  Telegram Bot API channel adapter (duplex).

  Inbound: Telegram posts one `Update` per webhook call to
  `POST /api/v1/channels/:id/inbound`, with the channel's `secret_token` in
  `X-Telegram-Bot-Api-Secret-Token` (`setWebhook`, see `register_webhook/2`).
  Outbound: Bot API methods (`sendMessage`, `sendPhoto`, `sendDocument`,
  `sendChatAction`).

  Telegram message ids are only unique within a chat, so a message is named
  `"<chat_id>:<message_id>"` everywhere: as the idempotency key of inbound
  messages and as the provider message id of outbound ones. Replies, edits
  and reactions refer to their target by that id. See
  `docs/channels/telegram.md`.
  """

  use Converger.Channels.Adapter, type: "telegram"

  alias Converger.{Activities, Participants, Uploads}
  alias Converger.Activities.ActivityAttachment
  alias Converger.Channels.{DeliveryError, InboundSignature}
  alias Converger.Pipeline.RetryPolicy

  require Logger

  @default_api_base_url "https://api.telegram.org"

  # Update types Converger handles. `message_reaction` is not sent by
  # Telegram unless listed in `allowed_updates`.
  @default_allowed_updates ~w(message edited_message callback_query message_reaction)

  @parse_modes ~w(MarkdownV2 Markdown HTML)

  # Bot API limits: callback data 1-64 bytes, secret token 1-256 of [A-Za-z0-9_-].
  @max_callback_data_bytes 64
  @secret_token_format ~r/\A[A-Za-z0-9_-]{1,256}\z/

  # The Bot API serves files up to 20 MB through getFile.
  @max_download_bytes 20 * 1024 * 1024

  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :typing,
      :provider_ack,
      :media,
      activity_types: ~w(message)
    ]
  end

  @impl true
  def config_schema do
    [
      %{
        name: "bot_token",
        type: :string,
        required: true,
        secret: true,
        label: "Bot Token",
        placeholder: "123456:ABC-DEF... (from @BotFather)"
      },
      %{
        name: "secret_token",
        type: :string,
        required: :with_signature,
        secret: true,
        label: "Secret Token",
        placeholder: "Sent as X-Telegram-Bot-Api-Secret-Token",
        help: "1-256 characters: A-Z, a-z, 0-9, _ and -"
      },
      %{
        name: "parse_mode",
        type: :string,
        label: "Parse mode",
        placeholder: "MarkdownV2, HTML or empty for plain text",
        summary: true
      },
      %{
        name: "allowed_updates",
        type: :string,
        label: "Allowed updates",
        placeholder: Enum.join(@default_allowed_updates, ","),
        help: "Comma-separated update types passed to setWebhook"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    secret = config["secret_token"]
    parse_mode = config["parse_mode"]

    cond do
      is_binary(secret) and secret != "" and not Regex.match?(@secret_token_format, secret) ->
        {:error,
         "telegram config 'secret_token' must be 1-256 characters of A-Z, a-z, 0-9, _ and -"}

      parse_mode not in [nil, "" | @parse_modes] ->
        {:error, "telegram config 'parse_mode' must be one of #{Enum.join(@parse_modes, ", ")}"}

      true ->
        case allowed_updates_value(config["allowed_updates"]) do
          {:ok, _} -> :ok
          :error -> {:error, "telegram config 'allowed_updates' must be a comma-separated string"}
        end
    end
  end

  # Bot API: about 30 messages per second per bot.
  @impl true
  def rate_limit, do: "30/s"

  ## Outbound

  @doc """
  Sends an activity to the chat: every media attachment with a `contentUrl`
  as a photo (`image/*`) or document, then the text with `sendMessage`. The
  buttons of `application/vnd.converger.card.*` attachments become an inline
  keyboard on the last message sent.

  The provider message id is the `"<chat_id>:<message_id>"` of the last
  message sent.
  """
  @impl true
  def deliver_activity(channel, activity) do
    metadata = activity.metadata || %{}

    # Not `telegram_chat_id`: inbound messages carry it, and one routed to
    # another Telegram channel must not be sent to a chat of a different bot.
    chat_id =
      metadata["chat_id"] ||
        Participants.recipient_for(activity, Map.get(channel, :id))

    if is_nil(chat_id) do
      {:error,
       DeliveryError.permanent(
         "no recipient: set activity metadata 'chat_id', or reply in a conversation with a participant on this channel"
       )}
    else
      case build_requests(channel, activity, to_string(chat_id)) do
        [] -> {:error, DeliveryError.permanent("nothing to send: no text or media")}
        requests -> send_all(channel, requests)
      end
    end
  end

  defp build_requests(channel, activity, chat_id) do
    attachments = activity.attachments || []
    keyboard = inline_keyboard(attachments)
    media = for a <- attachments, is_map(a), media?(a), do: a

    text = message_text(activity.text, attachments)

    media_requests =
      Enum.map(media, fn attachment ->
        {method, field} = media_method(attachment)

        {method, chat_id, %{field => {:media, attachment}}, caption_params(attachment)}
      end)

    text_requests =
      if text == "",
        do: [],
        else: [{"sendMessage", chat_id, %{"text" => text}, parse_mode_params(channel)}]

    put_keyboard(media_requests ++ text_requests, keyboard)
  end

  defp message_text(text, _attachments) when is_binary(text) and text != "", do: text
  defp message_text(_text, attachments), do: card_text(attachments)

  # The inline keyboard goes on the last message, after any text.
  defp put_keyboard([_ | _] = requests, %{} = keyboard) do
    {method, chat, params, extra} = List.last(requests)

    List.replace_at(
      requests,
      -1,
      {method, chat, params, Map.put(extra, "reply_markup", keyboard)}
    )
  end

  defp put_keyboard(requests, _keyboard), do: requests

  defp media?(%{"contentType" => content_type} = attachment) when is_binary(content_type) do
    is_binary(attachment["contentUrl"]) and
      not String.starts_with?(content_type, ActivityAttachment.card_prefix()) and
      content_type not in ActivityAttachment.well_known_content_types()
  end

  defp media?(_attachment), do: false

  defp media_method(%{"contentType" => "image/gif"}), do: {"sendDocument", "document"}
  defp media_method(%{"contentType" => "image/" <> _}), do: {"sendPhoto", "photo"}
  defp media_method(_attachment), do: {"sendDocument", "document"}

  defp caption_params(attachment) do
    case attachment["name"] do
      name when is_binary(name) and name != "" -> %{"caption" => name}
      _ -> %{}
    end
  end

  defp parse_mode_params(channel) do
    case (channel.config || %{})["parse_mode"] do
      mode when mode in @parse_modes -> %{"parse_mode" => mode}
      _ -> %{}
    end
  end

  defp card_text(attachments) do
    attachments
    |> Enum.filter(&card?/1)
    |> Enum.map(fn %{"content" => content} ->
      [content["title"], content["subtitle"], content["text"]]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("\n")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp card?(%{"contentType" => content_type, "content" => content})
       when is_binary(content_type) and is_map(content),
       do: String.starts_with?(content_type, ActivityAttachment.card_prefix())

  defp card?(_attachment), do: false

  @doc """
  The inline keyboard for the buttons of the card attachments, one row per
  button, or nil. `openUrl` buttons become URL buttons; any other button
  becomes a callback button whose data is its `value` (or its `title`),
  which must fit Telegram's 64-byte limit; longer ones are dropped.
  """
  def inline_keyboard(attachments) do
    rows =
      for attachment <- attachments,
          card?(attachment),
          button <- list(attachment["content"]["buttons"]),
          is_map(button),
          key = button_key(button),
          not is_nil(key),
          do: [key]

    if rows == [], do: nil, else: %{"inline_keyboard" => rows}
  end

  defp button_key(%{"title" => title} = button) when is_binary(title) and title != "" do
    value = button["value"]

    if button["type"] == "openUrl" and is_binary(value) do
      %{"text" => title, "url" => value}
    else
      callback_button(title, if(is_binary(value) and value != "", do: value, else: title))
    end
  end

  defp button_key(_button), do: nil

  defp callback_button(title, data) when byte_size(data) <= @max_callback_data_bytes,
    do: %{"text" => title, "callback_data" => data}

  defp callback_button(title, _data) do
    Logger.warning("Dropped a Telegram button: callback data over 64 bytes", reason: title)
    nil
  end

  defp send_all(channel, requests) do
    Enum.reduce_while(requests, {:ok, nil}, fn {method, chat_id, params, extra}, {:ok, _} ->
      case send_one(channel, method, chat_id, params, extra) do
        {:ok, message_id} -> {:cont, {:ok, message_id}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, provider_message_id} ->
        {:ok,
         %{
           provider_message_id: provider_message_id,
           telegram_message_id: provider_message_id,
           telegram_messages: length(requests)
         }}

      {:error, _} = error ->
        error
    end
  end

  defp send_one(channel, method, chat_id, params, extra) do
    case media_body(channel, params) do
      {:ok, body} ->
        body = body |> Map.merge(extra) |> Map.put("chat_id", chat_id)

        case call(channel, method, body,
               receive_timeout: RetryPolicy.for_channel(channel).timeout_ms
             ) do
          {:ok, %{"message_id" => message_id} = result} ->
            {:ok, "#{get_in(result, ["chat", "id"]) || chat_id}:#{message_id}"}

          {:ok, _result} ->
            {:ok, nil}

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  # A media field is sent by URL when Telegram can fetch it; an attachment
  # stored by Converger is not reachable without a token, so its bytes are
  # uploaded (multipart) instead.
  defp media_body(channel, params) do
    Enum.reduce_while(params, {:ok, %{}}, fn
      {field, {:media, attachment}}, {:ok, acc} ->
        case media_value(channel, attachment) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
          {:error, _} = error -> {:halt, error}
        end

      {field, value}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, field, value)}}
    end)
  end

  @attachment_path ~r|\A/api/v1/converger/attachments/([0-9a-fA-F-]{36})\z|

  defp media_value(channel, %{"contentUrl" => url} = attachment) do
    case Regex.run(@attachment_path, local_path(url)) do
      [_, id] -> stored_file(channel, id, attachment)
      nil -> {:ok, url}
    end
  end

  # The path of a URL served by this Converger (a server path, or an absolute
  # URL on the endpoint's host); "" for any other URL.
  defp local_path("/" <> _ = path), do: path

  defp local_path(url) do
    uri = URI.parse(url)
    endpoint = URI.parse(ConvergerWeb.Endpoint.url())

    if uri.host == endpoint.host and uri.port == endpoint.port, do: uri.path || "", else: ""
  end

  defp stored_file(channel, id, attachment) do
    case Uploads.get_attachment(channel.tenant_id, id) do
      nil ->
        {:error, DeliveryError.permanent("attachment #{id} not found")}

      stored ->
        case Uploads.storage().get(Uploads.storage_opts(), stored.storage_key) do
          {:ok, binary} ->
            {:ok,
             {:file, binary, attachment["name"] || stored.filename || "file", stored.content_type}}

          {:error, reason} ->
            {:error, DeliveryError.from_transport(reason, "attachment storage")}
        end
    end
  end

  @doc """
  Shows "typing..." in the chat (`sendChatAction`). Telegram clears it after
  about 5 seconds or when the next message arrives, so `isTyping: false`
  needs no call.
  """
  @impl true
  def send_typing(channel, %{is_typing: true, recipient: chat_id}) when is_binary(chat_id) do
    case call(channel, "sendChatAction", %{"chat_id" => chat_id, "action" => "typing"},
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def send_typing(_channel, _signal), do: :ok

  ## Bot API calls

  @doc """
  Calls a Bot API method. Returns `{:ok, result}` or `{:error,
  %DeliveryError{}}`. Bodies holding a `{:file, binary, name, type}` value
  are sent as `multipart/form-data`, others as JSON.
  """
  def call(channel, method, body, opts \\ []) do
    url = "#{api_base_url()}/bot#{(channel.config || %{})["bot_token"]}/#{method}"

    body_opts =
      if Enum.any?(body, fn {_k, v} -> match?({:file, _, _, _}, v) end),
        do: [form_multipart: Enum.map(body, &multipart_part/1)],
        else: [json: body]

    options =
      body_opts
      |> Keyword.merge(opts)
      |> Keyword.merge(Application.get_env(:converger, :telegram_req_options, []))

    case Req.post(url, options) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = response}} ->
        {:ok, response["result"]}

      {:ok, %Req.Response{status: status, headers: headers, body: response}} ->
        {:error, api_error(status, headers, response, method)}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, "Telegram API")}
    end
  end

  defp multipart_part({key, {:file, binary, filename, content_type}}),
    do: {key, {binary, filename: filename, content_type: content_type}}

  defp multipart_part({key, value}) when is_map(value) or is_list(value),
    do: {key, Jason.encode!(value)}

  defp multipart_part({key, value}), do: {key, to_string(value)}

  # Telegram puts the error in the body: `{"ok": false, "error_code": 429,
  # "description": "...", "parameters": {"retry_after": 5}}`. The bot token
  # is part of the URL, never of the error, so the reason is safe to store.
  defp api_error(status, headers, response, method) do
    error = DeliveryError.from_http(status, headers, describe(response), "Telegram #{method}")

    case response do
      %{"parameters" => %{"retry_after" => seconds}} when is_integer(seconds) ->
        %{error | retry_after_ms: seconds * 1000}

      _ ->
        error
    end
  end

  defp describe(%{"description" => description}), do: description
  defp describe(response), do: response

  @doc """
  Bot API base URL: `config :converger, #{inspect(__MODULE__)}, api_base_url:
  "..."` (a self-hosted Bot API server), else #{@default_api_base_url}. Only
  the operator sets it: a tenant-supplied URL would receive the bot token
  and could point at internal hosts.
  """
  def api_base_url do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:api_base_url, @default_api_base_url)
    |> String.trim_trailing("/")
  end

  @doc "Checks the bot token with `getMe`."
  @impl true
  def health_probe(channel) do
    case call(channel, "getMe", %{}, receive_timeout: 5_000, retry: false) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, DeliveryError.message(error)}
    end
  end

  @doc """
  Points the bot's webhook at `inbound_url` (`setWebhook`), with the
  channel's `secret_token` and `allowed_updates`. Called by the admin
  "Register webhook" button.
  """
  @impl true
  def register_webhook(channel, inbound_url) do
    config = channel.config || %{}
    {:ok, allowed_updates} = allowed_updates_value(config["allowed_updates"])

    body =
      %{"url" => inbound_url, "allowed_updates" => allowed_updates}
      |> put_present("secret_token", config["secret_token"])

    case call(channel, "setWebhook", body, receive_timeout: 10_000, retry: false) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, DeliveryError.message(error)}
    end
  end

  defp allowed_updates_value(value) when value in [nil, ""], do: {:ok, @default_allowed_updates}

  defp allowed_updates_value(value) when is_binary(value),
    do: {:ok, value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}

  defp allowed_updates_value(_value), do: :error

  ## Inbound

  @doc """
  Verifies `X-Telegram-Bot-Api-Secret-Token` against the channel's
  `secret_token` in constant time.

  Once a `secret_token` is configured every request must carry it: a missing
  or wrong header is `{:error, _}` (401). Without a configured secret the
  result is `:missing`, and the channel's `require_signature` decides.
  """
  @impl true
  def verify_inbound_signature(channel, headers, _raw_body) do
    secret = (channel.config || %{})["secret_token"]
    provided = InboundSignature.get_header(headers, "x-telegram-bot-api-secret-token")

    cond do
      not is_binary(secret) or secret == "" -> :missing
      is_nil(provided) -> {:error, :missing_secret_token}
      Plug.Crypto.secure_compare(provided, secret) -> :ok
      true -> {:error, :invalid_secret_token}
    end
  end

  @doc """
  Parses one Telegram `Update`: `message`, `edited_message` (a
  `messageUpdate`), `callback_query` (an `event`) and `message_reaction` (a
  `messageReaction`). Photos, documents, voice notes and other files are
  downloaded with `getFile` and stored as Converger attachments.

  Returns `{:ok, []}` for other update types and `{:error, _}` for a payload
  that is not an `Update`.
  """
  @impl true
  def parse_inbound(channel, %{"update_id" => update_id} = update) when is_integer(update_id) do
    messages =
      cond do
        is_map(update["message"]) ->
          [parse_message(channel, update["message"], update_id)]

        is_map(update["edited_message"]) ->
          [parse_edit(channel, update["edited_message"], update_id)]

        is_map(update["callback_query"]) ->
          parse_callback_query(channel, update["callback_query"], update_id)

        is_map(update["message_reaction"]) ->
          parse_reaction(update["message_reaction"], update_id)

        true ->
          []
      end

    {:ok, messages}
  end

  def parse_inbound(_channel, _params), do: {:error, "unable to parse Telegram update"}

  defp parse_message(channel, message, update_id) do
    chat = message["chat"] || %{}
    chat_id = to_string(chat["id"])
    key = message_key(chat_id, message["message_id"])
    {text, attachments, extra} = parse_content(channel, message, key)

    %{
      "sender" => sender(message, chat_id),
      "type" => "message",
      "text" => text,
      "attachments" => attachments,
      "metadata" => message_metadata(message, update_id) |> Map.merge(extra),
      "idempotency_key" => key,
      "reply_to_provider_id" => reply_target(chat_id, message),
      "participant" => participant(chat, message["from"])
    }
  end

  # An edit is a messageUpdate of the original, which Converger stored under
  # the same "<chat>:<message>" key. Each edit has its own edit_date, so a
  # re-delivered edit is a duplicate and a second edit is not.
  defp parse_edit(channel, message, update_id) do
    chat = message["chat"] || %{}
    chat_id = to_string(chat["id"])
    original = message_key(chat_id, message["message_id"])
    key = "#{original}:edit:#{message["edit_date"] || update_id}"
    {text, attachments, extra} = parse_content(channel, message, key)

    %{
      "sender" => sender(message, chat_id),
      "type" => "messageUpdate",
      "text" => text,
      "attachments" => attachments,
      "metadata" =>
        message_metadata(message, update_id)
        |> Map.merge(extra)
        |> put_present("edit_date", message["edit_date"]),
      "idempotency_key" => key,
      "reply_to_provider_id" => original,
      "participant" => participant(chat, message["from"])
    }
  end

  defp parse_callback_query(channel, query, update_id) do
    message = query["message"] || %{}
    chat = message["chat"] || %{}
    from = query["from"] || %{}
    chat_id = to_string(chat["id"] || from["id"])

    answer_callback_query(channel, query["id"])

    [
      %{
        "sender" => to_string(from["id"] || chat_id),
        "type" => "event",
        "text" => query["data"] || query["game_short_name"] || "",
        "attachments" => [],
        "metadata" =>
          reject_nil_values(%{
            "name" => "telegram.callback_query",
            "telegram_update_id" => update_id,
            "telegram_chat_id" => chat_id,
            "callback_query_id" => query["id"],
            "callback_data" => query["data"],
            "telegram_message_id" => message["message_id"]
          }),
        "idempotency_key" => "callback:#{query["id"] || update_id}",
        "reply_to_provider_id" => message_key(chat_id, message["message_id"]),
        "participant" => participant(chat, from)
      }
    ]
  end

  # Telegram keeps a spinner on the button until the query is answered.
  # Best effort, off the request path: the event is stored either way.
  defp answer_callback_query(_channel, nil), do: :ok

  defp answer_callback_query(channel, query_id) do
    Task.Supervisor.start_child(Converger.TaskSupervisor, fn ->
      case call(channel, "answerCallbackQuery", %{"callback_query_id" => query_id},
             receive_timeout: 5_000,
             retry: false
           ) do
        {:ok, _} ->
          :ok

        {:error, error} ->
          Logger.info("answerCallbackQuery failed",
            channel_id: Map.get(channel, :id),
            reason: DeliveryError.message(error)
          )
      end
    end)

    :ok
  end

  # The reaction is the first emoji of new_reaction; an empty list means the
  # user removed their reaction (text ""). Custom and paid reactions have no
  # emoji and keep their type in metadata.
  defp parse_reaction(reaction, update_id) do
    chat = reaction["chat"] || %{}
    chat_id = to_string(chat["id"])
    user = reaction["user"]
    new = list(reaction["new_reaction"])
    emoji = Enum.find_value(new, &(is_map(&1) && &1["emoji"]))

    [
      %{
        "sender" => to_string((user || %{})["id"] || chat_id),
        "type" => "messageReaction",
        "text" => emoji || "",
        "attachments" => [],
        "metadata" =>
          reject_nil_values(%{
            "telegram_update_id" => update_id,
            "telegram_chat_id" => chat_id,
            "telegram_message_id" => reaction["message_id"],
            "reaction" =>
              reject_nil_values(%{
                "message_id" => message_key(chat_id, reaction["message_id"]),
                "emoji" => emoji,
                "new_reaction" => new,
                "old_reaction" => list(reaction["old_reaction"])
              })
          }),
        "idempotency_key" => "update:#{update_id}",
        "reply_to_provider_id" => message_key(chat_id, reaction["message_id"]),
        "participant" => participant(chat, user)
      }
    ]
  end

  defp message_key(_chat_id, nil), do: nil
  defp message_key(chat_id, message_id), do: "#{chat_id}:#{message_id}"

  defp reply_target(chat_id, %{"reply_to_message" => %{"message_id" => id}}),
    do: message_key(chat_id, id)

  defp reply_target(_chat_id, _message), do: nil

  defp sender(message, chat_id) do
    case message["from"] do
      %{"id" => id} -> to_string(id)
      _ -> chat_id
    end
  end

  # The participant is the chat (a private chat, group or channel): replies
  # go to the chat. The display name is the sender's, or the chat title.
  defp participant(chat, from) do
    reject_nil_values(%{
      "external_id" => to_string(chat["id"]),
      "display_name" => display_name(from) || chat["title"]
    })
  end

  defp display_name(%{} = user) do
    case [user["first_name"], user["last_name"]] |> Enum.filter(&is_binary/1) do
      [] -> user["username"]
      names -> Enum.join(names, " ")
    end
  end

  defp display_name(_user), do: nil

  defp message_metadata(message, update_id) do
    chat = message["chat"] || %{}
    from = message["from"] || %{}

    reject_nil_values(%{
      "telegram_update_id" => update_id,
      "telegram_message_id" => message["message_id"],
      "telegram_chat_id" => to_string(chat["id"]),
      "telegram_chat_type" => chat["type"],
      "telegram_user_id" => from["id"],
      "username" => from["username"],
      "language_code" => from["language_code"],
      "timestamp" => message["date"],
      "reply_to" => get_in(message, ["reply_to_message", "message_id"]),
      "media_group_id" => message["media_group_id"]
    })
  end

  # file field => the attachment's default content type
  @file_fields [
    {"document", "application/octet-stream"},
    {"audio", "audio/mpeg"},
    {"voice", "audio/ogg"},
    {"video", "video/mp4"},
    {"video_note", "video/mp4"},
    {"animation", "video/mp4"},
    {"sticker", "image/webp"}
  ]

  # Returns {text, attachments, extra_metadata}.
  defp parse_content(channel, message, key) do
    text = message["text"] || message["caption"] || ""

    case content_kind(message) do
      {:photo, sizes} ->
        # PhotoSizes come smallest first; keep the largest.
        {text, [file_attachment(channel, List.last(sizes), "image/jpeg", "photo", key)], %{}}

      {:file, name, default_type} ->
        file_content(channel, message[name], name, default_type, key, text)

      :location ->
        location_content(message, text)

      :contact ->
        contact_content(message["contact"])

      :text ->
        {text, [], %{}}
    end
  end

  defp file_content(channel, file, name, default_type, key, text) do
    attachment = file_attachment(channel, file, file["mime_type"] || default_type, name, key)
    text = if text == "" and name == "sticker", do: file["emoji"] || "", else: text
    {text, [attachment], %{}}
  end

  defp content_kind(%{"photo" => [_ | _] = sizes}), do: {:photo, sizes}

  defp content_kind(message) do
    case Enum.find(@file_fields, fn {field, _} -> is_map(message[field]) end) do
      {name, default_type} -> {:file, name, default_type}
      nil -> other_kind(message)
    end
  end

  defp other_kind(%{"location" => %{}}), do: :location
  defp other_kind(%{"contact" => %{}}), do: :contact
  defp other_kind(_message), do: :text

  defp location_content(message, text) do
    location = message["location"]

    content =
      reject_nil_values(%{
        "latitude" => location["latitude"],
        "longitude" => location["longitude"],
        "name" => get_in(message, ["venue", "title"]),
        "address" => get_in(message, ["venue", "address"])
      })

    text =
      if text == "",
        do: Enum.join(Enum.filter([content["name"], content["address"]], & &1), ", "),
        else: text

    {text, [%{"contentType" => "application/vnd.converger.location", "content" => content}], %{}}
  end

  defp contact_content(contact) do
    name = Enum.join(Enum.filter([contact["first_name"], contact["last_name"]], & &1), " ")
    content = [reject_nil_values(%{"name" => name, "phones" => [contact["phone_number"]]})]

    {name, [%{"contentType" => "application/vnd.converger.contacts", "content" => content}], %{}}
  end

  defp file_attachment(channel, file, content_type, kind, key) do
    file_id = file["file_id"]

    base =
      reject_nil_values(%{
        "contentType" => content_type,
        "name" => file["file_name"],
        "size" => file["file_size"],
        "channelData" =>
          reject_nil_values(%{
            "provider" => "telegram",
            "kind" => kind,
            "fileId" => file_id,
            "fileUniqueId" => file["file_unique_id"],
            "duration" => file["duration"],
            "width" => file["width"],
            "height" => file["height"]
          })
      })

    case store_file(channel, file, key) do
      {:ok, stored} ->
        Map.merge(base, %{
          "contentUrl" => "/api/v1/converger/attachments/#{stored.id}",
          "contentType" => stored.content_type,
          "size" => stored.size
        })

      # The attachment keeps the file id, so a consumer can still fetch it.
      :skip ->
        base
    end
  end

  # Downloads the file with getFile and stores it as a Converger attachment.
  # The Bot API download URL embeds the bot token, so it is never exposed.
  # Skipped for a re-delivered message (it is a duplicate anyway), a file
  # over the size limit, or any failure (logged; the message is still kept).
  defp store_file(channel, %{"file_id" => file_id} = file, key) when is_binary(file_id) do
    max = min(Uploads.max_file_size(), @max_download_bytes)

    cond do
      not Map.has_key?(channel, :tenant_id) or is_nil(channel.tenant_id) ->
        :skip

      Activities.get_activity_by_channel_idempotency_key(channel.id, key) != nil ->
        :skip

      is_integer(file["file_size"]) and file["file_size"] > max ->
        Logger.info("Telegram file not downloaded: over the size limit",
          channel_id: channel.id,
          reason: "#{file["file_size"]} bytes"
        )

        :skip

      true ->
        with {:ok, %{"file_path" => path}} <-
               call(channel, "getFile", %{"file_id" => file_id},
                 receive_timeout: 10_000,
                 retry: false
               ),
             {:ok, binary} <- download(channel, path),
             {:ok, stored} <-
               Uploads.create_attachment(channel.tenant_id, {file_name(file, path), binary}) do
          {:ok, stored}
        else
          error ->
            Logger.warning("Telegram file not stored",
              channel_id: channel.id,
              reason: inspect(error)
            )

            :skip
        end
    end
  end

  defp store_file(_channel, _file, _key), do: :skip

  defp download(channel, path) do
    url = "#{api_base_url()}/file/bot#{channel.config["bot_token"]}/#{path}"

    options =
      [receive_timeout: 30_000, retry: false, decode_body: false]
      |> Keyword.merge(Application.get_env(:converger, :telegram_req_options, []))

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:download_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_name(%{"file_name" => name}, _path) when is_binary(name) and name != "", do: name
  defp file_name(_file, path), do: Path.basename(path)

  defp list(value) when is_list(value), do: value
  defp list(_), do: []

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
