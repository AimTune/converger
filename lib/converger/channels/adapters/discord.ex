defmodule Converger.Channels.Adapters.Discord do
  @moduledoc """
  Discord bot channel adapter (duplex).

    * Inbound: the application's Interactions Endpoint URL
      (`POST /api/v1/channels/:id/inbound`): slash commands, message
      components (buttons, selects) and modal submits, signed with Ed25519
      (`X-Signature-Ed25519` over `X-Signature-Timestamp` + body, with the
      application's public key). `PING` is answered in-band, and each
      interaction gets the interaction response Discord requires within three
      seconds (`inbound_response/2`).
    * Outbound: `POST /channels/{channel_id}/messages` with the bot token:
      text (split at 2000 characters), card buttons as button components and
      files (stored uploads are uploaded). Replies go to the channel or
      thread the user last interacted in, or to `metadata.target_channel_id`;
      `metadata.thread_name` starts a thread.

    * Gateway (optional, `gateway: true`): plain channel and direct messages
      (`MESSAGE_CREATE`) over the Discord Gateway WebSocket, one connection
      per channel in the cluster (`Converger.Channels.Discord.Gateway`, run
      by `Converger.Channels.Consumers` like a broker consumer).

  See `docs/channels/discord.md`.
  """

  use Converger.Channels.Adapter, type: "discord"

  @behaviour Converger.Channels.Broker

  import Bitwise

  alias Converger.Channels.{Broker, ChatContent, DeliveryError, InboundSignature, MediaDownload}
  alias Converger.Channels.Discord.Gateway
  alias Converger.Channels.WhatsApp.Outbound
  alias Converger.{Participants, Uploads}
  alias Converger.Pipeline.RetryPolicy

  @default_api_base_url "https://discord.com/api/v10"

  # Interaction types and callback types.
  @ping 1
  @application_command 2
  @message_component 3
  @autocomplete 4
  @modal_submit 5

  @pong 1
  @channel_message 4
  @deferred_update 6
  @autocomplete_result 8
  @ephemeral 64

  # Discord limits: message content 2000 characters, 5 buttons per action
  # row, 5 rows, labels 80 and custom ids 100 characters, 10 files.
  @max_content 2000
  @max_buttons 25
  @max_label 80
  @max_custom_id 100
  @max_files 10

  # Thread channel types: announcement, public and private threads.
  @thread_types [10, 11, 12]

  @default_ack "Got it, a reply is on its way."

  # Gateway intents: GUILD_MESSAGES (1 << 9), DIRECT_MESSAGES (1 << 12) and
  # the privileged MESSAGE_CONTENT (1 << 15).
  @default_intents 37_376
  @max_intents 1 <<< 26

  # Message types turned into activities: DEFAULT (0) and REPLY (19).
  @message_types [0, 19]

  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :provider_ack,
      :media,
      :consumer,
      activity_types: ~w(message),
      # Typed media messages arrive as file attachments (#68, ADR-0064);
      # actions as a numbered list (Converger.Channels.RichContent).
      message_types: ~w(image file video audio)
    ]
  end

  @impl true
  def config_schema do
    [
      %{
        name: "application_id",
        type: :string,
        required: true,
        label: "Application ID",
        placeholder: "e.g. 1234567890123456789",
        summary: true
      },
      %{
        name: "public_key",
        type: :string,
        label: "Public Key",
        placeholder: "64 hex characters, verifies X-Signature-Ed25519",
        help: "Required for the Interactions Endpoint; optional in Gateway mode"
      },
      %{
        name: "bot_token",
        type: :string,
        required: true,
        secret: true,
        label: "Bot Token",
        placeholder: "From the Bot page of the application"
      },
      %{
        name: "command_ack_text",
        type: :string,
        label: "Command acknowledgement",
        placeholder: @default_ack,
        help:
          "Ephemeral reply to slash commands and modal submits, shown while the real reply is prepared"
      },
      %{
        name: "gateway",
        type: :boolean,
        label: "Gateway (plain messages)",
        help:
          "Receive channel and direct messages over the Discord Gateway (inbound and duplex mode; default false)"
      },
      %{
        name: "gateway_intents",
        type: :integer,
        label: "Gateway intents",
        placeholder: "#{@default_intents}",
        help:
          "Intents bitfield; default GUILD_MESSAGES, DIRECT_MESSAGES and MESSAGE_CONTENT (privileged: enable it in the developer portal)"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    gateway? = Broker.boolean(config["gateway"])

    cond do
      config["public_key"] in [nil, ""] and not gateway? ->
        {:error, "discord config missing: public_key (required unless gateway is true)"}

      config["public_key"] not in [nil, ""] and
          not Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, to_string(config["public_key"])) ->
        {:error, "discord config 'public_key' must be 64 hex characters"}

      not valid_intents?(config["gateway_intents"]) ->
        {:error,
         "discord config 'gateway_intents' must be an integer from 0 to #{@max_intents - 1}"}

      not Regex.match?(~r/\A\d+\z/, to_string(config["application_id"])) ->
        {:error, "discord config 'application_id' must be a numeric id"}

      true ->
        :ok
    end
  end

  defp valid_intents?(blank) when blank in [nil, ""], do: true

  defp valid_intents?(value) do
    case Broker.positive_integer(value, nil) do
      int when is_integer(int) -> int < @max_intents
      nil -> value in [0, "0"]
    end
  end

  # Discord's global limit: 50 requests per second per bot.
  @impl true
  def rate_limit, do: "50/s"

  ## Inbound

  @doc """
  Verifies `X-Signature-Ed25519` (hex) over `X-Signature-Timestamp` followed
  by the raw body, with the channel's `public_key`. The timestamp must be
  within the inbound signature tolerance (300 s by default). Discord signs
  every request, so a missing header is rejected.
  """
  @impl true
  def verify_inbound_signature(channel, headers, raw_body) do
    with {:ok, public_key} <- public_key(channel),
         {:ok, signature, timestamp} <- signature_headers(headers),
         :ok <- check_timestamp(timestamp) do
      message = timestamp <> (raw_body || "")

      if :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519]),
        do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  # A channel without a public key (Gateway only) rejects every interaction.
  defp public_key(channel) do
    case Base.decode16(to_string((channel.config || %{})["public_key"]), case: :mixed) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
      _ -> {:error, :public_key_not_configured}
    end
  end

  defp signature_headers(headers) do
    with signature when is_binary(signature) <-
           InboundSignature.get_header(headers, "x-signature-ed25519"),
         timestamp when is_binary(timestamp) <-
           InboundSignature.get_header(headers, "x-signature-timestamp"),
         {:ok, <<_::binary-size(64)>> = signature} <- Base.decode16(signature, case: :mixed) do
      {:ok, signature, timestamp}
    else
      nil -> {:error, :missing_signature}
      _ -> {:error, :malformed_signature}
    end
  end

  defp check_timestamp(timestamp) do
    case Integer.parse(timestamp) do
      {seconds, ""} ->
        if abs(System.system_time(:second) - seconds) <= InboundSignature.tolerance_seconds(),
          do: :ok,
          else: {:error, :timestamp_out_of_tolerance}

      _ ->
        {:error, :malformed_signature}
    end
  end

  @doc "Answers Discord's `PING` (type 1) with a `PONG`, without creating anything."
  @impl true
  def inbound_challenge(_channel, %{"type" => @ping}), do: {:ok, %{"type" => @pong}}
  def inbound_challenge(_channel, _params), do: :none

  @doc """
  The interaction response of a handled interaction: an ephemeral message
  (`command_ack_text`) for slash commands and modal submits, a deferred
  update (no visible change) for components, and no choices for
  autocomplete.
  """
  @impl true
  def inbound_response(channel, %{"type" => type})
      when type in [@application_command, @modal_submit] do
    ack = (channel.config || %{})["command_ack_text"]
    content = if is_binary(ack) and ack != "", do: ack, else: @default_ack

    json(%{"type" => @channel_message, "data" => %{"content" => content, "flags" => @ephemeral}})
  end

  def inbound_response(_channel, %{"type" => @message_component}),
    do: json(%{"type" => @deferred_update})

  def inbound_response(_channel, %{"type" => @autocomplete}),
    do: json(%{"type" => @autocomplete_result, "data" => %{"choices" => []}})

  def inbound_response(_channel, _params), do: :default

  defp json(body), do: {"application/json", Jason.encode!(body)}

  @doc """
  Parses one interaction: a slash command becomes a `message` (`/name` and
  the option values), a modal submit a `message` with the submitted values,
  and a component (button, select) an `event` whose text is its `custom_id`.

  The participant is the Discord user; the channel (or thread) of the
  interaction is stored in its metadata (`discord_channel_id`, updated on
  every interaction), so replies go to where the user last interacted.
  """
  @impl true
  def parse_inbound(
        _channel,
        %{"type" => type, "id" => id, "channel" => %{"id" => _}} = interaction
      )
      when type in [@application_command, @message_component, @modal_submit] do
    {:ok, [interaction_message(type, id, interaction)]}
  end

  def parse_inbound(_channel, %{"type" => @autocomplete}), do: {:ok, []}

  def parse_inbound(_channel, _params), do: {:error, "unable to parse Discord interaction"}

  defp interaction_message(type, id, interaction) do
    user = get_in(interaction, ["member", "user"]) || interaction["user"] || %{}
    data = interaction["data"] || %{}
    # Not the top-level `channel_id`: the inbound controller's params carry
    # Converger's own `channel_id` path parameter under that key.
    channel = interaction["channel"] || %{}
    channel_id = channel["id"]
    {activity_type, text, extra} = content(type, data, interaction)

    %{
      "sender" => user["id"],
      "type" => activity_type,
      "text" => text,
      "attachments" => [],
      "metadata" =>
        reject_nil_values(%{
          "discord_interaction_id" => id,
          "discord_channel_id" => channel_id,
          "discord_guild_id" => interaction["guild_id"],
          "discord_user_id" => user["id"],
          "username" => user["username"],
          "locale" => interaction["locale"],
          "discord_thread_id" => if(channel["type"] in @thread_types, do: channel_id)
        })
        |> Map.merge(extra),
      "idempotency_key" => "interaction:#{id}",
      "reply_to_provider_id" => get_in(interaction, ["message", "id"]),
      "participant" =>
        reject_nil_values(%{
          "external_id" => user["id"],
          "display_name" =>
            get_in(interaction, ["member", "nick"]) || user["global_name"] || user["username"],
          "metadata" => %{"discord_channel_id" => channel_id}
        })
    }
  end

  defp content(@application_command, data, _interaction) do
    options = flatten_options(data["options"])
    values = for %{"value" => value} <- options, do: to_string(value)

    {"message", Enum.join(["/#{data["name"]}" | values], " "),
     %{"discord_command" => reject_nil_values(%{"name" => data["name"], "options" => options})}}
  end

  defp content(@message_component, data, _interaction) do
    {"event", to_string(data["custom_id"] || ""),
     %{
       "name" => "discord.component",
       "discord_component" =>
         reject_nil_values(%{
           "custom_id" => data["custom_id"],
           "component_type" => data["component_type"],
           "values" => data["values"]
         })
     }}
  end

  defp content(@modal_submit, data, _interaction) do
    values =
      for row <- list(data["components"]),
          component <- list(row["components"]),
          is_binary(component["value"]),
          do: %{"custom_id" => component["custom_id"], "value" => component["value"]}

    {"message", Enum.map_join(values, "\n", & &1["value"]),
     %{"discord_modal" => %{"custom_id" => data["custom_id"], "values" => values}}}
  end

  # Subcommands and groups nest their options; keep the leaf values in order.
  defp flatten_options(options) do
    Enum.flat_map(list(options), fn
      %{"options" => nested} = option when is_list(nested) ->
        [Map.take(option, ["name", "type"]) | flatten_options(nested)]

      option when is_map(option) ->
        [Map.take(option, ["name", "type", "value"])]

      _ ->
        []
    end)
  end

  ## Outbound

  @doc """
  Sends an activity to `metadata.target_channel_id` (a channel or thread
  id), else to the Discord channel the conversation's participant last
  interacted in: files stored in Converger are uploaded with the first
  message, link attachments are appended to the text, card buttons become
  button components on the last message. With `metadata.thread_name` a
  public thread is started from the first message and the rest is posted
  into it.

  The inbound keys `discord_channel_id` / `discord_thread_id` are not used,
  so an interaction routed to another Discord channel is never posted with
  the wrong bot. The provider message id is the id of the last message sent.
  """
  @impl true
  def deliver_activity(channel, activity) do
    metadata = Map.get(activity, :metadata) || %{}
    target = metadata["target_channel_id"] || participant_channel(channel, activity)

    if is_nil(target) do
      {:error,
       DeliveryError.permanent(
         "no recipient: set activity metadata 'target_channel_id', or reply in a conversation with a participant on this channel"
       )}
    else
      with {:ok, files, links} <- files(channel, activity) do
        payloads = build_payloads(activity, links, files)

        if payloads == [],
          do: {:error, DeliveryError.permanent("nothing to send: no text or media")},
          else: send_all(channel, to_string(target), payloads, metadata["thread_name"])
      end
    end
  end

  defp participant_channel(channel, activity) do
    case Participants.participant_for(activity, Map.get(channel, :id)) do
      %{metadata: %{"discord_channel_id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp files(channel, activity) do
    ChatContent.media(activity)
    |> Enum.reduce_while({:ok, [], []}, fn attachment, {:ok, files, links} ->
      case Outbound.media_source(channel, attachment, "discord") do
        {:stored, stored} ->
          case read_stored(stored, attachment) do
            {:ok, file} -> {:cont, {:ok, files ++ [file], links}}
            {:error, _} = error -> {:halt, error}
          end

        {:link, url} ->
          {:cont, {:ok, files, links ++ [url]}}

        {:provider_id, _id} ->
          {:cont, {:ok, files, links}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _links} when length(files) > @max_files ->
        {:error,
         DeliveryError.permanent("Discord accepts at most #{@max_files} files per message")}

      other ->
        other
    end
  end

  defp read_stored(stored, attachment) do
    case Uploads.storage().get(Uploads.storage_opts(), stored.storage_key) do
      {:ok, data} ->
        {:ok, {data, attachment["name"] || stored.filename || stored.id, stored.content_type}}

      {:error, :not_found} ->
        {:error, DeliveryError.permanent("attachment #{stored.id} file is missing")}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, "attachment storage")}
    end
  end

  defp build_payloads(activity, links, files) do
    text = Enum.join(Enum.reject([ChatContent.text(activity) | links], &(&1 == "")), "\n")
    chunks = ChatContent.split(text, @max_content)
    components = components(ChatContent.buttons(activity))

    payloads =
      case {chunks, files} do
        {[], []} ->
          []

        {[], files} ->
          [%{"content" => "", "files" => files}]

        {[first | rest], files} ->
          [%{"content" => first, "files" => files} | for(c <- rest, do: %{"content" => c})]
      end

    case {payloads, components} do
      {[], _} ->
        []

      {payloads, []} ->
        payloads

      {payloads, components} ->
        List.update_at(payloads, -1, &Map.put(&1, "components", components))
    end
  end

  # Buttons in action rows of five: link buttons (style 5) for openUrl,
  # primary buttons (style 1) whose custom_id is the button payload.
  defp components([]), do: []

  defp components(buttons) do
    buttons
    |> Enum.take(@max_buttons)
    |> Enum.map(fn button ->
      label = String.slice(button["title"], 0, @max_label)

      if button["url"],
        do: %{"type" => 2, "style" => 5, "label" => label, "url" => button["url"]},
        else: %{
          "type" => 2,
          "style" => 1,
          "label" => label,
          "custom_id" => String.slice(button["payload"], 0, @max_custom_id)
        }
    end)
    |> Enum.chunk_every(5)
    |> Enum.map(&%{"type" => 1, "components" => &1})
  end

  defp send_all(channel, target, [first | rest], thread_name)
       when is_binary(thread_name) and thread_name != "" do
    with {:ok, message_id} <- post_message(channel, target, first),
         {:ok, thread_id} <- start_thread(channel, target, message_id, thread_name),
         {:ok, meta} <- send_all(channel, thread_id, rest, nil) do
      ids = [message_id | meta.discord_message_ids]

      {:ok,
       %{
         provider_message_id: List.last(ids),
         discord_message_ids: ids,
         discord_thread_id: thread_id
       }}
    end
  end

  defp send_all(channel, target, payloads, _thread_name) do
    payloads
    |> Enum.reduce_while({:ok, []}, fn payload, {:ok, ids} ->
      case post_message(channel, target, payload) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} ->
        ids = Enum.reverse(ids)
        {:ok, %{provider_message_id: List.last(ids), discord_message_ids: ids}}

      {:error, _} = error ->
        error
    end
  end

  defp post_message(channel, target, payload) do
    {files, payload} = Map.pop(payload, "files", [])
    timeout = RetryPolicy.for_channel(channel).timeout_ms
    path = "/channels/#{URI.encode(target, &URI.char_unreserved?/1)}/messages"

    body_options =
      if files == [] do
        [json: payload]
      else
        attachments =
          files
          |> Enum.with_index()
          |> Enum.map(fn {{_, name, _}, i} -> %{"id" => i, "filename" => name} end)

        parts =
          for {{data, name, type}, i} <- Enum.with_index(files),
              do: {"files[#{i}]", {data, filename: name, content_type: type}}

        [
          form_multipart: [
            {"payload_json", Jason.encode!(Map.put(payload, "attachments", attachments))} | parts
          ]
        ]
      end

    case request(channel, :post, path, body_options ++ [receive_timeout: timeout]) do
      {:ok, %{"id" => id}} -> {:ok, id}
      {:ok, _} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  # A public thread (auto-archived after a day) started from the message.
  defp start_thread(channel, target, message_id, name) do
    path = "/channels/#{target}/messages/#{message_id}/threads"
    body = %{"name" => String.slice(name, 0, 100), "auto_archive_duration" => 1440}

    case request(channel, :post, path, json: body, receive_timeout: 10_000) do
      {:ok, %{"id" => id}} -> {:ok, id}
      {:ok, _} -> {:error, DeliveryError.permanent("Discord did not return the thread")}
      {:error, _} = error -> error
    end
  end

  @doc """
  Calls the Discord HTTP API with the bot token. Returns `{:ok, body}` for
  2xx answers and `{:error, %DeliveryError{}}` otherwise: `429` (with
  `retry_after`) and `5xx` are retried, other statuses (missing permissions,
  unknown channel, invalid form body) are permanent.
  """
  def request(channel, method, path, options) do
    options =
      [
        method: method,
        url: api_base_url() <> path,
        headers: [{"authorization", "Bot #{(channel.config || %{})["bot_token"]}"}]
      ]
      |> Keyword.merge(options)
      |> Keyword.merge(Application.get_env(:converger, :discord_req_options, []))

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:error, api_error(status, headers, body)}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, "Discord API")}
    end
  end

  defp api_error(status, headers, body) do
    error = DeliveryError.from_http(status, headers, body, "Discord API")

    case body do
      %{"retry_after" => seconds} when is_number(seconds) ->
        %{error | retry_after_ms: round(seconds * 1000)}

      _ ->
        error
    end
  end

  @doc """
  Discord API base URL: `config :converger, #{inspect(__MODULE__)},
  api_base_url: "..."`, else #{@default_api_base_url}. An operator setting
  only: the URL receives the bot token.
  """
  def api_base_url do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:api_base_url, @default_api_base_url)
    |> String.trim_trailing("/")
  end

  @doc "Checks the bot token with `GET /users/@me`."
  @impl true
  def health_probe(channel) do
    case request(channel, :get, "/users/@me", receive_timeout: 5_000, retry: false) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, DeliveryError.message(error)}
    end
  end

  @doc """
  Sets the application's Interactions Endpoint URL to `inbound_url`
  (`PATCH /applications/@me`). Discord checks the URL with a signed `PING`
  and an invalid signature before it accepts it.
  """
  @impl true
  def register_webhook(channel, inbound_url) do
    case request(channel, :patch, "/applications/@me",
           json: %{"interactions_endpoint_url" => inbound_url},
           receive_timeout: 15_000,
           retry: false
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, DeliveryError.message(error)}
    end
  end

  ## Gateway (Converger.Channels.Broker)

  @doc "A channel consumes the Gateway only with `gateway: true`."
  @impl Converger.Channels.Broker
  def consume?(channel), do: Broker.boolean((channel.config || %{})["gateway"])

  @impl Converger.Channels.Broker
  def consumer_child_spec(channel), do: {Gateway, channel}

  @doc "The Gateway intents of the channel: `gateway_intents`, else #{@default_intents}."
  def gateway_intents(channel) do
    case (channel.config || %{})["gateway_intents"] do
      value when value in [0, "0"] -> 0
      value -> Broker.positive_integer(value, @default_intents)
    end
  end

  @doc """
  The Gateway URL to connect to: `config :converger, #{inspect(__MODULE__)},
  gateway_url: "..."` (an operator setting, used by the tests), else the
  `url` of `GET /gateway/bot`. `?v=10&encoding=json` is appended.
  """
  @spec gateway_url(map()) :: {:ok, String.t()} | {:error, term()}
  def gateway_url(channel) do
    configured = Keyword.get(Application.get_env(:converger, __MODULE__, []), :gateway_url)

    result =
      if is_binary(configured) and configured != "" do
        {:ok, configured}
      else
        case request(channel, :get, "/gateway/bot", receive_timeout: 10_000, retry: false) do
          {:ok, %{"url" => url}} when is_binary(url) -> {:ok, url}
          {:ok, _} -> {:error, :no_gateway_url}
          {:error, _} = error -> error
        end
      end

    with {:ok, url} <- result, do: {:ok, gateway_query(url)}
  end

  @doc false
  def gateway_query(url) do
    uri = URI.parse(url)
    query = URI.encode_query(%{"v" => "10", "encoding" => "json"})
    URI.to_string(%{uri | path: uri.path || "/", query: query})
  end

  @doc """
  The inbound message of a Gateway `MESSAGE_CREATE` event, or `:ignore`:
  messages of the bot itself (`bot_user_id`) and of other bots, webhook
  and system messages, and messages without text or attachments (in a
  guild, without the MESSAGE_CONTENT intent).

  The participant and sender are the author; the Discord channel is stored
  in the participant's metadata (`discord_channel_id`), so replies go back
  there. Idempotency key: `message:<message id>`. Attachments are stubs the
  inbound media step downloads and stores (`fetch_media/2`); Discord CDN
  URLs expire.
  """
  @spec parse_gateway_message(map(), String.t() | nil) :: {:ok, map()} | :ignore
  def parse_gateway_message(%{"id" => id, "channel_id" => channel_id} = data, bot_user_id)
      when is_binary(id) and is_binary(channel_id) do
    author = data["author"] || %{}
    text = data["content"] || ""
    attachments = for a <- list(data["attachments"]), is_map(a), do: gateway_attachment(a)

    if ignored_author?(author, bot_user_id) or ignored_message?(data, text, attachments),
      do: :ignore,
      else: {:ok, gateway_message(data, author, text, attachments)}
  end

  def parse_gateway_message(_data, _bot_user_id), do: :ignore

  defp ignored_author?(author, bot_user_id),
    do: not is_binary(author["id"]) or author["id"] == bot_user_id or author["bot"] == true

  defp ignored_message?(data, text, attachments) do
    not is_nil(data["webhook_id"]) or data["type"] not in @message_types or
      (String.trim(text) == "" and attachments == [])
  end

  defp gateway_message(data, author, text, attachments) do
    channel_id = data["channel_id"]

    %{
      "sender" => author["id"],
      "type" => "message",
      "text" => if(text == "", do: nil, else: text),
      "attachments" => attachments,
      "metadata" =>
        reject_nil_values(%{
          "discord_message_id" => data["id"],
          "discord_channel_id" => channel_id,
          "discord_guild_id" => data["guild_id"],
          "discord_user_id" => author["id"],
          "username" => author["username"],
          "discord_source" => "gateway"
        }),
      "idempotency_key" => "message:#{data["id"]}",
      "reply_to_provider_id" => get_in(data, ["message_reference", "message_id"]),
      "participant" =>
        reject_nil_values(%{
          "external_id" => author["id"],
          "display_name" =>
            get_in(data, ["member", "nick"]) || author["global_name"] || author["username"],
          "metadata" => %{"discord_channel_id" => channel_id}
        })
    }
  end

  defp gateway_attachment(attachment) do
    name = attachment["filename"]

    reject_nil_values(%{
      "contentType" =>
        attachment["content_type"] ||
          if(is_binary(name), do: MIME.from_path(name), else: "application/octet-stream"),
      "name" => name,
      "channelData" =>
        reject_nil_values(%{
          "provider" => "discord",
          "kind" => "attachment",
          "providerMediaUrl" => attachment["url"],
          "size" => attachment["size"]
        })
    })
  end

  @doc """
  Downloads a Gateway message attachment from the Discord CDN (no
  credentials, through the SSRF guard, bounded by the upload size limit).
  """
  @impl true
  def fetch_media(_channel, %{
        "channelData" => %{"provider" => "discord", "providerMediaUrl" => url}
      })
      when is_binary(url),
      do: MediaDownload.get_public(url, :discord_req_options)

  def fetch_media(_channel, _attachment), do: :skip

  defp list(value) when is_list(value), do: value
  defp list(_), do: []

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
