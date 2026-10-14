defmodule Converger.Channels.Adapters.Mekik do
  @moduledoc """
  The `mekik` channel: Converger dials a mekik/1 server, one upstream
  WebSocket per conversation (Mode A of #64, ADR-0066,
  docs/channels/mekik.md).

  A routing rule that targets a `mekik` channel from an end-user channel
  (WhatsApp, Telegram, a `websocket` widget, ...) makes the mekik server the
  conversation's bot (`ConvergerWeb.Protocol.BotRelay`, capability
  `:bot_relay`):

    * `deliver_activity/2` sends the end user's turns upstream on the
      conversation's connection (`Converger.Channels.Mekik.Connections`): a
      `text` turn as mekik/1 `{type: "text", data: {text}, meta}`, a rich
      message as a `text` turn with its fallback text and the typed message
      under `data.message`, and a turn that answers an open `interrupt`
      (`replyTo` naming it, e.g. a tapped WhatsApp button) as `resume`.
      Everything else delivered to the channel (the bot's own replies,
      other parties) is acknowledged and not sent;
    * the end users' bot-only frames (`resume`, `genui_event`, `abort`, ...)
      and per-turn `meta` reach the connection through
      `Converger.Channels.Mekik.Relay`;
    * the mekik server's frames are stored or relayed by
      `Converger.Channels.Mekik.Connection`.

  ## Config

    * `url` (required) - the mekik server's WebSocket URL (`ws://` or `wss://`)
    * `token` (secret) - sent as `hello.token` and as `Authorization: Bearer`
    * `meta` (map) - mekik/1 client meta: `hello.meta`, and merged into every
      turn's `meta`
    * `bot_id` - the sender of the bot's activities (default `"mekik"`)
    * `idle_timeout_seconds` - an upstream connection without traffic for
      this long is closed (default 300)

  ## Operator settings

      config :converger, Converger.Channels.Adapters.Mekik,
        connect_timeout_ms: 10_000,
        call_timeout_ms: 15_000,
        backoff_base_ms: 1_000,
        max_backoff_ms: 30_000,
        auth_retry_ms: 60_000,
        relay_scan_interval_ms: 60_000
  """

  use Converger.Channels.Adapter, type: "mekik"

  alias Converger.Activities.Activity
  alias Converger.{Channels, Conversations, Participants}
  alias Converger.Channels.{DeliveryError, UrlGuard}
  alias Converger.Channels.Mekik.{Connections, Relay}
  alias Converger.Conversations.Conversation
  alias ConvergerWeb.Protocol.{BotRelay, Frames}

  @default_sender "mekik"
  @default_idle_seconds 300

  @settings %{
    connect_timeout_ms: 10_000,
    call_timeout_ms: 15_000,
    backoff_base_ms: 1_000,
    max_backoff_ms: 30_000,
    auth_retry_ms: 60_000,
    relay_scan_interval_ms: 60_000
  }

  # Frame types of a delivered activity that are not user turns.
  @not_turns ~w(event conversationUpdate typing)

  @impl true
  def capabilities,
    do: [:inbound, :outbound, :external_delivery, :bot_relay, {:message_types, :all}]

  # The bot's frames are stored as inbound activities of the channel, and
  # the end user's turns are delivered to it: always both directions.
  @impl true
  def supported_modes, do: ["duplex"]

  @impl true
  def config_schema do
    [
      %{
        name: "url",
        type: :string,
        required: true,
        summary: true,
        label: "mekik server URL",
        placeholder: "wss://bot.example.com/ws",
        help: "The mekik/1 WebSocket endpoint (ws:// or wss://)"
      },
      %{
        name: "token",
        type: :string,
        secret: true,
        label: "Token",
        help: "Sent as hello.token and as an Authorization: Bearer header"
      },
      %{
        name: "meta",
        type: :map,
        label: "Meta",
        help: "mekik/1 client meta (JSON object): hello.meta and merged into every turn's meta"
      },
      %{
        name: "bot_id",
        type: :string,
        label: "Bot id",
        placeholder: @default_sender,
        help: "Sender of the bot's activities (default mekik)"
      },
      %{
        name: "idle_timeout_seconds",
        type: :integer,
        label: "Idle timeout (s)",
        placeholder: "#{@default_idle_seconds}",
        help: "Close a conversation's upstream connection after this long without traffic"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_url(config["url"]),
         :ok <- validate_idle(config["idle_timeout_seconds"]) do
      validate_bot_id(config["bot_id"])
    end
  end

  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["ws", "wss"] or not is_binary(uri.host) or uri.host == "" ->
        {:error, "mekik config 'url' must be a ws:// or wss:// URL"}

      uri.userinfo != nil ->
        {:error, "mekik config 'url' must not carry credentials (use token)"}

      true ->
        http = String.replace_prefix(url, "ws", "http")

        case UrlGuard.check(http) do
          :ok -> :ok
          {:error, message} -> {:error, "mekik config 'url' is not allowed: #{message}"}
        end
    end
  end

  defp validate_url(_url), do: {:error, "mekik config 'url' must be a ws:// or wss:// URL"}

  defp validate_idle(blank) when blank in [nil, ""], do: :ok

  defp validate_idle(value) do
    case integer(value) do
      seconds when is_integer(seconds) and seconds in 1..86_400 -> :ok
      _ -> {:error, "mekik config 'idle_timeout_seconds' must be between 1 and 86400"}
    end
  end

  defp validate_bot_id(blank) when blank in [nil, ""], do: :ok
  defp validate_bot_id(id) when is_binary(id) and byte_size(id) <= 256, do: :ok
  defp validate_bot_id(_id), do: {:error, "mekik config 'bot_id' must be at most 256 bytes"}

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp integer(_value), do: nil

  @doc "The sender of the channel's bot activities (config `bot_id`, default `\"mekik\"`)."
  def sender(%{config: %{"bot_id" => id}}) when is_binary(id) and id != "", do: id
  def sender(_channel), do: @default_sender

  @doc "The idle timeout of the channel's upstream connections, in ms."
  def idle_timeout_ms(channel) do
    case integer((channel.config || %{})["idle_timeout_seconds"]) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds * 1_000
      _ -> @default_idle_seconds * 1_000
    end
  end

  @doc "An operator setting (see the module doc)."
  def setting(key) do
    Application.get_env(:converger, __MODULE__, [])
    |> Keyword.get(key, Map.fetch!(@settings, key))
  end

  ## Delivery

  @impl true
  def deliver_activity(channel, activity) do
    Relay.watch(channel.id)

    case Conversations.get_conversation(activity.conversation_id) do
      %Conversation{} = conversation ->
        case upstream_frame(channel, conversation, activity) do
          {:ok, frame} -> Connections.deliver(channel, conversation.id, frame)
          :skip -> {:ok, %{skipped: "not an end-user turn"}}
        end

      nil ->
        {:error, DeliveryError.permanent("conversation not found")}
    end
  end

  @doc """
  The mekik/1 frame for a delivered activity: `{:ok, frame}` for an end
  user's turn, `:skip` for anything else.
  """
  def upstream_frame(channel, %Conversation{} = conversation, activity) do
    origin_channel_id = Conversation.origin_channel_id(conversation)
    viewer = {:agent, sender(channel), origin_channel_id}

    case render(activity, viewer) do
      %{"from" => "user", "type" => type} = frame when type not in @not_turns ->
        case BotRelay.turn_frame(frame, conversation.id) do
          %{"type" => "resume"} = resume ->
            {:ok, resume}

          frame ->
            meta = turn_meta(channel, conversation, activity, origin_channel_id)
            {:ok, user_turn(frame, activity, meta)}
        end

      _ ->
        :skip
    end
  end

  defp render(%Activity{} = activity, viewer), do: Frames.activity(activity, viewer)

  defp render(activity, viewer) do
    activity |> Map.put_new(:source_channel_id, nil) |> Frames.activity(viewer)
  end

  # mekik/1 knows one user turn: `text`. A rich message (an image, a shared
  # location, ...) travels as a text turn with its fallback text, carrying
  # the typed message under `data.message` for graphs that want it.
  defp user_turn(%{"type" => "text"} = frame, _activity, meta) do
    data = Map.take(frame["data"] || %{}, ["text", "attachments"])
    data = Map.put_new(data, "text", "")
    put_meta(%{"type" => "text", "data" => data}, meta)
  end

  defp user_turn(%{"type" => type} = frame, activity, meta) do
    message = frame |> Map.take(["id", "data"]) |> Map.put("type", type)
    text = Map.get(activity, :text) || ""
    put_meta(%{"type" => "text", "data" => %{"text" => text, "message" => message}}, meta)
  end

  defp put_meta(frame, meta) when map_size(meta) > 0, do: Map.put(frame, "meta", meta)
  defp put_meta(frame, _meta), do: frame

  # The turn's meta: the end user's per-turn meta (relayed ahead of the
  # turn), under the channel's configured meta, under Converger's context.
  defp turn_meta(channel, conversation, activity, origin_channel_id) do
    turn = Relay.take_meta(conversation.id, Map.get(activity, :idempotency_key)) || %{}

    configured =
      case (channel.config || %{})["meta"] do
        meta when is_map(meta) -> meta
        _ -> %{}
      end

    turn
    |> Map.merge(configured)
    |> Map.merge(context(conversation, origin_channel_id))
  end

  defp context(conversation, origin_channel_id) do
    origin =
      case Channels.get_channel(origin_channel_id) do
        %{id: id, type: type} -> %{"id" => id, "type" => type}
        nil -> %{"id" => origin_channel_id}
      end

    participant =
      case conversation.participant_id &&
             Participants.get_participant(conversation.participant_id) do
        %{id: id, external_id: external_id} -> %{"id" => id, "externalId" => external_id}
        _ -> nil
      end

    %{"conversationId" => conversation.id, "channel" => origin}
    |> then(&if(participant, do: Map.put(&1, "participant", participant), else: &1))
  end

  @impl true
  def parse_inbound(_channel, _params) do
    {:error,
     "mekik channels receive the bot's frames over their upstream WebSocket, not inbound webhooks"}
  end
end
