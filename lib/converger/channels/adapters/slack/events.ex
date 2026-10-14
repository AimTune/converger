defmodule Converger.Channels.Adapters.Slack.Events do
  @moduledoc """
  Parses Slack Events API callbacks and Block Kit interactions into inbound
  messages for `Converger.Channels.Adapters.Slack`.

  ## Mapping

  | Slack | Activity |
  | --- | --- |
  | `message` (plain, `file_share`, `thread_broadcast`), `app_mention` | `message` |
  | `message` / `message_changed` | `messageUpdate` of the edited message |
  | `message` / `message_deleted` | `messageDelete` of the deleted message |
  | `reaction_added` / `reaction_removed` | `messageReaction` (`:name:`, empty when removed) |
  | `block_actions` (a card button click) | `message` whose text is the button value |

  Messages posted by bots (`bot_id` set, or subtype `bot_message`), including
  Converger's own replies, are ignored, as are other subtypes (joins, topic
  changes, ...) and event types.

  A message is identified by `"<channel>:<ts>"` (Slack's `ts` is unique per
  channel). It is the idempotency key of inbound messages, so a `message`
  and an `app_mention` event for the same message, or a retried callback,
  create one activity, and it is the provider message id of outbound
  deliveries, so threads, reactions, edits and deletes resolve to the
  activity they refer to.

  ## Conversations

  The participant's `external_id` (which selects the conversation, see
  `Converger.Participants`) depends on the channel config key
  `conversation_scope`:

    * `"thread"` (default) - `"<channel>:<thread root ts>"`: one conversation
      per Slack thread; a top-level message starts a thread rooted at itself;
    * `"channel"` - `"<channel>"`: one conversation per Slack channel;
    * `"user"` - `"<channel>:<user>"`: one conversation per user and channel.
  """

  alias Converger.{Activities, Participants}
  alias Converger.Channels.RichContent

  require Logger

  @scopes ~w(thread channel user)
  @message_subtypes [nil, "file_share", "thread_broadcast"]
  @max_attachments 10

  @doc "Accepted values of the `conversation_scope` config key."
  def scopes, do: @scopes

  @doc "The channel's conversation scope (`thread` by default)."
  def scope(channel) do
    case (Map.get(channel, :config) || %{})["conversation_scope"] do
      scope when scope in @scopes -> scope
      _ -> "thread"
    end
  end

  @doc "The provider message id of a Slack message: `<channel>:<ts>`."
  def message_ref(slack_channel, ts) when is_binary(slack_channel) and is_binary(ts),
    do: slack_channel <> ":" <> ts

  def message_ref(_slack_channel, _ts), do: nil

  @doc """
  Parse a request body: an `event_callback`, an interaction (`payload`) or
  another well-formed Events API body (`{:ok, []}`). See the moduledoc.
  """
  def parse(channel, %{"type" => "event_callback", "event" => event} = params)
      when is_map(event) do
    if app_matches?(channel, params["api_app_id"]) do
      {:ok, List.wrap(parse_event(channel, event, params))}
    else
      Logger.warning("Ignored Slack event for another app (#{params["api_app_id"]})",
        channel_id: Map.get(channel, :id)
      )

      {:ok, []}
    end
  end

  # Interactivity requests are form-encoded: `payload=<json>`.
  def parse(channel, %{"payload" => payload}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "block_actions"} = interaction} ->
        if app_matches?(channel, interaction["api_app_id"]),
          do: {:ok, parse_block_actions(channel, interaction)},
          else: {:ok, []}

      {:ok, %{"type" => _}} ->
        {:ok, []}

      _ ->
        {:error, "unable to parse Slack interaction payload"}
    end
  end

  # url_verification is answered before parsing (Slack.inbound_challenge/2);
  # app_rate_limited and other notices carry no message.
  def parse(_channel, %{"type" => type}) when is_binary(type), do: {:ok, []}

  def parse(_channel, _params), do: {:error, "unable to parse Slack Events API payload"}

  defp app_matches?(channel, api_app_id) do
    case (Map.get(channel, :config) || %{})["app_id"] do
      app_id when is_binary(app_id) and app_id != "" -> app_id == api_app_id
      _ -> true
    end
  end

  ## Events

  defp parse_event(channel, %{"type" => type} = event, params)
       when type in ["message", "app_mention"] do
    cond do
      bot?(event) -> nil
      event["subtype"] == "message_changed" -> parse_edit(channel, event, params)
      event["subtype"] == "message_deleted" -> parse_delete(channel, event, params)
      event["subtype"] in @message_subtypes -> parse_message(channel, event, params)
      true -> nil
    end
  end

  defp parse_event(channel, %{"type" => type} = event, params)
       when type in ["reaction_added", "reaction_removed"] do
    parse_reaction(channel, event, params)
  end

  defp parse_event(_channel, _event, _params), do: nil

  defp bot?(event),
    do: is_binary(event["bot_id"]) or event["subtype"] == "bot_message"

  defp parse_message(channel, event, params) do
    slack_channel = event["channel"]
    ts = event["ts"]
    thread_ts = event["thread_ts"]
    user = event["user"]

    %{
      "type" => "message",
      "text" => event["text"] || "",
      "attachments" => event |> Map.get("files") |> files() |> Enum.take(@max_attachments),
      "sender" => user || "slack",
      "idempotency_key" => message_ref(slack_channel, ts),
      # A reply in a thread refers to the thread root (an inbound message, or
      # one Converger posted).
      "reply_to_provider_id" =>
        if(thread_ts && thread_ts != ts, do: message_ref(slack_channel, thread_ts)),
      "metadata" =>
        base_metadata(event, params)
        |> Map.merge(%{"slack_ts" => ts, "slack_thread_ts" => thread_ts})
        |> reject_nil_values(),
      "participant" => participant(channel, slack_channel, user, thread_ts || ts)
    }
  end

  defp parse_edit(channel, event, params) do
    message = event["message"] || %{}
    slack_channel = event["channel"]

    if bot?(message) do
      nil
    else
      %{
        "type" => "messageUpdate",
        "text" => message["text"] || "",
        "sender" => message["user"] || "slack",
        "idempotency_key" => edit_key(slack_channel, message, params),
        "reply_to_provider_id" => message_ref(slack_channel, message["ts"]),
        "metadata" =>
          base_metadata(event, params)
          |> Map.merge(%{"slack_ts" => message["ts"], "slack_thread_ts" => message["thread_ts"]})
          |> reject_nil_values(),
        "participant" =>
          participant(
            channel,
            slack_channel,
            message["user"],
            message["thread_ts"] || message["ts"]
          )
      }
    end
  end

  # Two edits of a message are two updates: key them by the edit time.
  defp edit_key(slack_channel, message, params) do
    case get_in(message, ["edited", "ts"]) do
      edited when is_binary(edited) ->
        "#{message_ref(slack_channel, message["ts"])}:edit:#{edited}"

      _ ->
        params["event_id"]
    end
  end

  defp parse_delete(channel, event, params) do
    previous = event["previous_message"] || %{}
    slack_channel = event["channel"]
    deleted_ts = event["deleted_ts"] || previous["ts"]

    # Converger's own messages deleted with chat.delete come back as events.
    if bot?(previous) do
      nil
    else
      %{
        "type" => "messageDelete",
        "text" => "",
        "sender" => previous["user"] || "slack",
        "idempotency_key" => "#{message_ref(slack_channel, deleted_ts)}:delete",
        "reply_to_provider_id" => message_ref(slack_channel, deleted_ts),
        "metadata" =>
          base_metadata(event, params)
          |> Map.merge(%{"slack_ts" => deleted_ts, "slack_thread_ts" => previous["thread_ts"]})
          |> reject_nil_values(),
        "participant" =>
          participant(
            channel,
            slack_channel,
            previous["user"],
            previous["thread_ts"] || deleted_ts
          )
      }
    end
  end

  defp parse_reaction(channel, event, params) do
    item = event["item"] || %{}
    slack_channel = item["channel"]
    target = message_ref(slack_channel, item["ts"])
    name = event["reaction"]

    if item["type"] == "message" and is_binary(target) do
      %{
        "type" => "messageReaction",
        # Like WhatsApp: the emoji (here its Slack name), empty when removed.
        "text" =>
          if(event["type"] == "reaction_added" and is_binary(name), do: ":#{name}:", else: ""),
        "sender" => event["user"] || "slack",
        "idempotency_key" =>
          params["event_id"] || "#{target}:#{event["type"]}:#{name}:#{event["user"]}",
        "reply_to_provider_id" => target,
        "metadata" =>
          base_metadata(event, params)
          |> Map.merge(%{
            "reaction" => reject_nil_values(%{"name" => name, "message_id" => target}),
            "slack_ts" => item["ts"]
          })
          |> reject_nil_values(),
        "participant" => reaction_participant(channel, slack_channel, event["user"], target)
      }
    end
  end

  # A reaction names only the message (channel + ts), not its thread; in the
  # thread scope the conversation is the one of the reacted-to message.
  defp reaction_participant(channel, slack_channel, user, target) do
    known =
      if scope(channel) == "thread" and is_binary(Map.get(channel, :id)) do
        case Activities.get_activity_by_provider_message_id(channel.id, target) do
          %{} = activity -> Participants.recipient_for(activity, channel.id)
          nil -> nil
        end
      end

    case known do
      external_id when is_binary(external_id) ->
        %{"external_id" => external_id}

      nil ->
        [_channel, ts] = String.split(target, ":", parts: 2)
        participant(channel, slack_channel, user, ts)
    end
  end

  ## Interactions

  defp parse_block_actions(channel, interaction) do
    container = interaction["container"] || %{}
    message = interaction["message"] || %{}
    slack_channel = get_in(interaction, ["channel", "id"]) || container["channel_id"]
    user = get_in(interaction, ["user", "id"])
    message_ts = container["message_ts"] || message["ts"]
    root_ts = message["thread_ts"] || message_ts

    context = %{
      interaction: interaction,
      message: message,
      slack_channel: slack_channel,
      user: user,
      message_ts: message_ts,
      participant: participant(channel, slack_channel, user, root_ts)
    }

    interaction
    |> Map.get("actions")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&parse_action(&1, context))
  end

  defp parse_action(
         action,
         %{slack_channel: slack_channel, user: user, message_ts: message_ts} = context
       ) do
    interaction = context.interaction
    label = get_in(action, ["text", "text"])

    %{
      "type" => "message",
      "text" => action["value"] || label || "",
      "sender" => user || "slack",
      "idempotency_key" =>
        "#{message_ref(slack_channel, message_ts)}:action:#{action["action_ts"] || interaction["trigger_id"]}:#{action["action_id"]}",
      "reply_to_provider_id" => message_ref(slack_channel, message_ts),
      "metadata" =>
        reject_nil_values(%{
          "slack_event_type" => "block_actions",
          "slack_channel" => slack_channel,
          "slack_team" => get_in(interaction, ["team", "id"]),
          "slack_user" => user,
          "slack_ts" => message_ts,
          "slack_thread_ts" => context.message["thread_ts"],
          "interactive_reply" =>
            reject_nil_values(%{
              "type" => "button",
              "id" => action["action_id"],
              "title" => label,
              "payload" => action["value"]
            })
        }),
      "participant" => context.participant
    }
    |> button_answer(action["value"], label)
  end

  # A click on a button Converger rendered for a typed message (#68): its
  # value is an answer key, normalised by Converger.Inbound.Answers; the
  # button label is the text if the key does not resolve.
  defp button_answer(message, value, label) do
    case RichContent.parse_ref(value) do
      {:ok, _id, _index} ->
        message
        |> Map.put("text", label || "")
        |> RichContent.put_answer(value, "button", label)

      :error ->
        message
    end
  end

  ## Helpers

  defp participant(channel, slack_channel, user, root_ts) do
    external_id =
      case scope(channel) do
        "channel" -> slack_channel
        "user" -> join(slack_channel, user)
        "thread" -> join(slack_channel, root_ts)
      end

    %{"external_id" => external_id}
  end

  defp join(a, b) when is_binary(a) and is_binary(b), do: a <> ":" <> b
  defp join(a, _b), do: a

  defp base_metadata(event, params) do
    reject_nil_values(%{
      "slack_event_type" => event_type(event),
      "slack_event_id" => params["event_id"],
      "slack_channel" => event["channel"] || get_in(event, ["item", "channel"]),
      "slack_channel_type" => event["channel_type"],
      "slack_team" => params["team_id"] || event["team"],
      "slack_user" => event["user"] || get_in(event, ["message", "user"])
    })
  end

  defp event_type(%{"type" => type, "subtype" => subtype}) when is_binary(subtype),
    do: "#{type}.#{subtype}"

  defp event_type(%{"type" => type}), do: type

  defp files(files) when is_list(files) do
    for file <- files, is_map(file) do
      reject_nil_values(%{
        "contentType" => file["mimetype"] || "application/octet-stream",
        "name" => file["name"],
        "size" => file["size"],
        "channelData" =>
          reject_nil_values(%{
            "provider" => "slack",
            "fileId" => file["id"],
            "urlPrivate" => file["url_private"],
            "urlPrivateDownload" => file["url_private_download"],
            "permalink" => file["permalink"],
            "fileAccess" => file["file_access"]
          })
      })
    end
  end

  defp files(_files), do: []

  defp reject_nil_values(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
