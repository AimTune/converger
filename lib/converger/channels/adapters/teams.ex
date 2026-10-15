defmodule Converger.Channels.Adapters.Teams do
  @moduledoc """
  Microsoft Teams channel adapter (duplex), on the Bot Framework (an Azure
  Bot registration with the Teams channel).

    * Inbound: the Bot Connector posts Activities to the bot's messaging
      endpoint (`POST /api/v1/channels/:id/inbound`), authenticated with a
      Bot Framework JWT (`Converger.Channels.Teams.Auth.verify_request/3`).
    * Outbound: `POST <serviceUrl>/v3/conversations/<id>/activities` with
      an OAuth client-credentials token, to the service URL and
      conversation the participant last wrote from (kept in its metadata),
      checked against the Bot Framework host allowlist.
    * Typing indicators are forwarded as `typing` activities.

  Teams message ids are only unique within a conversation, so a message is
  named `"<conversation hash>:<id>"` (`message_key/2`). See
  `docs/channels/teams.md` and ADR-0048.
  """

  use Converger.Channels.Adapter, type: "teams"

  alias Converger.Channels.{ChatContent, DeliveryError, MediaDownload}
  alias Converger.Channels.Teams.Auth
  alias Converger.Channels.WhatsApp.Outbound
  alias Converger.Participants
  alias Converger.Pipeline.RetryPolicy

  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :typing,
      :provider_ack,
      :media,
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
        name: "app_id",
        type: :string,
        required: true,
        label: "Microsoft App ID",
        placeholder: "00000000-0000-0000-0000-000000000000",
        summary: true
      },
      %{
        name: "app_password",
        type: :string,
        required: true,
        secret: true,
        label: "Client secret",
        placeholder: "App registration client secret"
      },
      %{
        name: "app_tenant_id",
        type: :string,
        label: "App tenant ID",
        placeholder: "Single-tenant bots only",
        help: "The Microsoft Entra tenant of a single-tenant bot; empty for multi-tenant bots"
      },
      %{
        name: "download_media",
        type: :boolean,
        label: "Download inbound files",
        help: "Store inbound files and inline images in Converger (default true)"
      }
    ]
  end

  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @impl true
  def validate_config(config) do
    tenant = config["app_tenant_id"]

    cond do
      not Regex.match?(@uuid, to_string(config["app_id"])) ->
        {:error, "teams config 'app_id' must be the Microsoft App ID (a GUID)"}

      is_binary(tenant) and tenant != "" and
          not Regex.match?(~r/\A[A-Za-z0-9.-]{1,255}\z/, tenant) ->
        {:error, "teams config 'app_tenant_id' must be a tenant id or domain"}

      true ->
        :ok
    end
  end

  # Teams throttles a bot at about 50 requests per second per tenant (and
  # 7 per second per conversation); the channel rate limit covers the first.
  @impl true
  def rate_limit, do: "50/s"

  ## Inbound

  @doc """
  Verifies the Bot Connector JWT in `Authorization` (see
  `Converger.Channels.Teams.Auth.verify_request/3`). The Bot Connector
  always sends one, so a missing token is rejected.
  """
  @impl true
  def verify_inbound_signature(channel, headers, raw_body) do
    case Auth.verify_request((channel.config || %{})["app_id"], headers, raw_body) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  The name of a Teams message in Converger: `"<first 16 hex of
  sha256(conversation id)>:<activity id>"`. Used as the idempotency key of
  inbound messages and the provider message id of outbound ones.
  """
  def message_key(conversation_id, id) when is_binary(conversation_id) and is_binary(id) do
    hash =
      :crypto.hash(:sha256, conversation_id) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    "#{hash}:#{id}"
  end

  def message_key(_conversation_id, _id), do: nil

  @doc """
  Parses one Bot Framework Activity: `message` (an Adaptive Card submit
  without text is an `event`), `messageReaction`, `messageUpdate`,
  `messageDelete` and the `adaptiveCard/action` invoke. Other activity types
  (`conversationUpdate`, `typing`, `installationUpdate`, ...) carry nothing
  and are acknowledged.
  """
  @impl true
  def parse_inbound(
        _channel,
        %{"type" => type, "conversation" => %{"id" => conversation_id}, "from" => %{"id" => _}} =
          activity
      )
      when is_binary(type) and is_binary(conversation_id) do
    {:ok, parse_activity(type, activity, conversation_id)}
  end

  def parse_inbound(_channel, _params), do: {:error, "unable to parse Bot Framework activity"}

  defp parse_activity("message", activity, conversation_id) do
    text = strip_bot_mention(activity)
    value = activity["value"]
    key = message_key(conversation_id, activity["id"])

    if text == "" and not is_nil(value) do
      [
        base(activity)
        |> Map.merge(%{
          "type" => "event",
          "text" => "",
          "idempotency_key" => key,
          "reply_to_provider_id" => message_key(conversation_id, activity["replyToId"])
        })
        |> merge_metadata(%{"name" => "teams.card_action", "value" => value})
      ]
    else
      [
        base(activity)
        |> Map.merge(%{
          "type" => "message",
          "text" => text,
          "attachments" => attachments(activity["attachments"]),
          "idempotency_key" => key,
          "reply_to_provider_id" => message_key(conversation_id, activity["replyToId"])
        })
        |> merge_metadata(%{"value" => value})
      ]
    end
  end

  defp parse_activity("messageReaction", activity, conversation_id) do
    target = message_key(conversation_id, activity["replyToId"])
    added = for %{"type" => t} <- list(activity["reactionsAdded"]), do: {t, t}
    removed = for %{"type" => t} <- list(activity["reactionsRemoved"]), do: {t, ""}

    (added ++ removed)
    |> Enum.with_index()
    |> Enum.map(fn {{reaction, text}, index} ->
      base(activity)
      |> Map.merge(%{
        "type" => "messageReaction",
        "text" => text,
        "idempotency_key" => "#{message_key(conversation_id, activity["id"])}:reaction:#{index}",
        "reply_to_provider_id" => target
      })
      |> merge_metadata(%{
        "reaction" => %{
          "message_id" => target,
          "type" => reaction,
          "action" => if(text == "", do: "removed", else: "added")
        }
      })
    end)
  end

  # Teams sends an edit with the id of the edited message.
  defp parse_activity("messageUpdate", activity, conversation_id) do
    key = message_key(conversation_id, activity["id"])

    [
      base(activity)
      |> Map.merge(%{
        "type" => "messageUpdate",
        "text" => strip_bot_mention(activity),
        "idempotency_key" => "#{key}:edit:#{activity["timestamp"]}",
        "reply_to_provider_id" => key
      })
    ]
  end

  defp parse_activity("messageDelete", activity, conversation_id) do
    key = message_key(conversation_id, activity["id"])

    [
      base(activity)
      |> Map.merge(%{
        "type" => "messageDelete",
        "text" => "",
        "idempotency_key" => "#{key}:delete",
        "reply_to_provider_id" => key
      })
    ]
  end

  defp parse_activity("invoke", %{"name" => "adaptiveCard/action"} = activity, conversation_id) do
    action = get_in(activity, ["value", "action"]) || %{}

    [
      base(activity)
      |> Map.merge(%{
        "type" => "event",
        "text" => to_string(action["verb"] || ""),
        "idempotency_key" => message_key(conversation_id, activity["id"]),
        "reply_to_provider_id" => message_key(conversation_id, activity["replyToId"])
      })
      |> merge_metadata(%{"name" => "teams.card_action", "value" => action})
    ]
  end

  defp parse_activity(_type, _activity, _conversation_id), do: []

  defp base(activity) do
    from = activity["from"] || %{}
    conversation = activity["conversation"] || %{}
    channel_data = activity["channelData"] || %{}
    tenant_id = get_in(channel_data, ["tenant", "id"]) || conversation["tenantId"]

    %{
      "sender" => from["id"],
      "attachments" => [],
      "metadata" =>
        reject_nil_values(%{
          "teams_activity_id" => activity["id"],
          "teams_conversation_id" => conversation["id"],
          "teams_conversation_type" => conversation["conversationType"],
          "teams_tenant_id" => tenant_id,
          "teams_team_id" => get_in(channel_data, ["team", "id"]),
          "teams_channel_id" => get_in(channel_data, ["channel", "id"]),
          "aad_object_id" => from["aadObjectId"],
          "bot_framework_channel" => activity["channelId"],
          "locale" => activity["locale"],
          "timestamp" => activity["timestamp"]
        }),
      # Where replies go: the conversation and service URL the participant
      # last wrote from (merged on every inbound message).
      "participant" =>
        reject_nil_values(%{
          "external_id" => from["id"],
          "display_name" => from["name"],
          "metadata" =>
            reject_nil_values(%{
              "service_url" => activity["serviceUrl"],
              "conversation_id" => conversation["id"],
              "bot_id" => get_in(activity, ["recipient", "id"]),
              "tenant_id" => tenant_id
            })
        })
    }
  end

  defp merge_metadata(message, extra),
    do: Map.update!(message, "metadata", &Map.merge(&1, reject_nil_values(extra)))

  # In channels and group chats the bot is @mentioned: drop its <at> tag.
  defp strip_bot_mention(activity) do
    bot_id = get_in(activity, ["recipient", "id"])

    mentions =
      for %{"type" => "mention", "text" => tag} = entity <- list(activity["entities"]),
          get_in(entity, ["mentioned", "id"]) == bot_id,
          is_binary(tag),
          do: tag

    mentions
    |> Enum.reduce(to_string(activity["text"]), &String.replace(&2, &1, ""))
    |> String.trim()
  end

  @file_download "application/vnd.microsoft.teams.file.download.info"

  defp attachments(attachments) do
    for attachment <- list(attachments),
        is_map(attachment),
        parsed = attachment(attachment),
        not is_nil(parsed),
        do: parsed
  end

  # A file shared in a chat: a pre-authenticated SharePoint download URL.
  defp attachment(%{"contentType" => @file_download, "content" => %{} = content} = attachment) do
    name = attachment["name"]

    reject_nil_values(%{
      "contentType" =>
        if(is_binary(name), do: MIME.from_path(name), else: "application/octet-stream"),
      "name" => name,
      "channelData" =>
        reject_nil_values(%{
          "provider" => "teams",
          "kind" => "file",
          "providerMediaUrl" => content["downloadUrl"],
          "fileType" => content["fileType"]
        })
    })
  end

  # An inline image: fetched from the Bot Connector with the bot's token.
  defp attachment(%{"contentType" => "image/" <> _ = type, "contentUrl" => url} = attachment)
       when is_binary(url) do
    reject_nil_values(%{
      "contentType" => type,
      "name" => attachment["name"],
      "channelData" => %{
        "provider" => "teams",
        "kind" => "inline",
        "providerMediaUrl" => url
      }
    })
  end

  # The HTML rendering of the message text duplicates `text`.
  defp attachment(%{"contentType" => "text/html"}), do: nil

  defp attachment(%{"contentType" => type} = attachment) when is_binary(type) do
    reject_nil_values(%{
      "contentType" => type,
      "content" => attachment["content"],
      "contentUrl" => attachment["contentUrl"],
      "name" => attachment["name"]
    })
  end

  defp attachment(_attachment), do: nil

  @doc """
  Answers an `adaptiveCard/action` invoke with the Universal Action
  response Teams expects; other requests get the JSON summary.
  """
  @impl true
  def inbound_response(_channel, %{"type" => "invoke", "name" => "adaptiveCard/action"}) do
    {"application/json",
     Jason.encode!(%{
       "statusCode" => 200,
       "type" => "application/vnd.microsoft.activity.message",
       "value" => "Received"
     })}
  end

  def inbound_response(_channel, _params), do: :default

  @doc """
  Downloads an inbound file: shared files from their pre-authenticated URL
  (checked by `Converger.Channels.UrlGuard`), inline images from the Bot
  Connector with the bot's token, only on an allowed Bot Framework host.
  """
  @impl true
  def fetch_media(_channel, %{"channelData" => %{"kind" => "file", "providerMediaUrl" => url}})
      when is_binary(url),
      do: MediaDownload.get_public(url, :teams_req_options)

  def fetch_media(channel, %{"channelData" => %{"kind" => "inline", "providerMediaUrl" => url}})
      when is_binary(url) do
    config = channel.config || %{}

    with :ok <- Auth.check_service_url(url),
         {:ok, token} <- Auth.access_token(config),
         {:ok, data} <-
           MediaDownload.get(
             url,
             [headers: [{"authorization", "Bearer #{token}"}]],
             :teams_req_options
           ) do
      {:ok, %{data: data, filename: nil}}
    end
  end

  def fetch_media(_channel, _attachment), do: :skip

  ## Outbound

  @doc """
  Sends an activity as one Bot Framework `message` to the conversation of
  the participant (or `metadata.target_conversation_id` with
  `metadata.target_service_url`): the text as markdown, card buttons as a
  hero card (`imBack` / `openUrl`), Adaptive Cards
  (`application/vnd.microsoft.card.*` attachments) as they are, and media
  with a public `contentUrl` as attachments. The provider message id is
  `message_key/2` of the returned id.
  """
  @impl true
  def deliver_activity(channel, activity) do
    config = channel.config || %{}

    with {:ok, target} <- target(channel, activity),
         :ok <- check_service_url(target.service_url),
         {:ok, attachments} <- outbound_attachments(channel, activity) do
      text = ChatContent.text(activity)

      if text == "" and attachments == [] do
        {:error, DeliveryError.permanent("nothing to send: no text or attachments")}
      else
        body =
          %{
            "type" => "message",
            "from" => %{"id" => target.bot_id || "28:#{config["app_id"]}"},
            "conversation" => %{"id" => target.conversation_id}
          }
          |> put_present("text", text)
          |> put_present("textFormat", if(text != "", do: "markdown"))
          |> put_present("attachments", if(attachments != [], do: attachments))

        timeout = RetryPolicy.for_channel(channel).timeout_ms

        with {:ok, response} <- post_activity(config, target, body, timeout) do
          key = message_key(target.conversation_id, response["id"])
          {:ok, reject_nil_values(%{provider_message_id: key, teams_activity_id: response["id"]})}
        end
      end
    end
  end

  defp target(channel, activity) do
    metadata = Map.get(activity, :metadata) || %{}

    cond do
      is_binary(metadata["target_conversation_id"]) and is_binary(metadata["target_service_url"]) ->
        {:ok,
         %{
           conversation_id: metadata["target_conversation_id"],
           service_url: metadata["target_service_url"],
           bot_id: nil
         }}

      participant = Participants.participant_for(activity, Map.get(channel, :id)) ->
        participant_target(participant)

      true ->
        no_recipient()
    end
  end

  defp participant_target(%{
         metadata: %{"conversation_id" => conversation_id, "service_url" => url} = metadata
       })
       when is_binary(conversation_id) and is_binary(url),
       do:
         {:ok, %{conversation_id: conversation_id, service_url: url, bot_id: metadata["bot_id"]}}

  defp participant_target(_participant), do: no_recipient()

  defp no_recipient do
    {:error,
     DeliveryError.permanent(
       "no recipient: reply in a conversation with a Teams participant, or set metadata 'target_conversation_id' and 'target_service_url'"
     )}
  end

  defp check_service_url(url) do
    case Auth.check_service_url(url) do
      :ok -> :ok
      {:error, message} -> {:error, DeliveryError.permanent(message)}
    end
  end

  @hero "application/vnd.microsoft.card.hero"

  defp outbound_attachments(channel, activity) do
    passthrough =
      for %{"contentType" => "application/vnd.microsoft.card." <> _ = type} = a <-
            List.wrap(Map.get(activity, :attachments)),
          do: %{"contentType" => type, "content" => a["content"]}

    media =
      ChatContent.media(activity)
      |> Enum.reject(
        &String.starts_with?(to_string(&1["contentType"]), "application/vnd.microsoft.card.")
      )
      |> Enum.reduce_while({:ok, []}, fn attachment, {:ok, acc} ->
        case Outbound.media_source(channel, attachment, "teams") do
          {:link, url} ->
            item =
              put_present(
                %{"contentType" => attachment["contentType"], "contentUrl" => url},
                "name",
                attachment["name"]
              )

            {:cont, {:ok, acc ++ [item]}}

          {:stored, stored} ->
            {:halt,
             {:error,
              DeliveryError.permanent(
                "Teams cannot fetch Converger attachment #{stored.id}: send media with a public contentUrl"
              )}}

          {:provider_id, _} ->
            {:cont, {:ok, acc}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    with {:ok, media} <- media do
      {:ok, media ++ passthrough ++ hero_card(ChatContent.buttons(activity))}
    end
  end

  defp hero_card([]), do: []

  defp hero_card(buttons) do
    actions =
      for b <- buttons do
        if b["url"],
          do: %{"type" => "openUrl", "title" => b["title"], "value" => b["url"]},
          else: %{"type" => "imBack", "title" => b["title"], "value" => b["payload"]}
      end

    [%{"contentType" => @hero, "content" => %{"buttons" => actions}}]
  end

  defp post_activity(config, target, body, timeout) do
    url =
      "#{String.trim_trailing(target.service_url, "/")}/v3/conversations/" <>
        "#{URI.encode(target.conversation_id, &URI.char_unreserved?/1)}/activities"

    with {:ok, token} <- Auth.access_token(config) do
      options =
        [
          json: body,
          headers: [{"authorization", "Bearer #{token}"}],
          receive_timeout: timeout
        ]
        |> Keyword.merge(Auth.req_options())

      case Req.post(url, options) do
        {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
          {:ok, if(is_map(response), do: response, else: %{})}

        # An expired or revoked token: drop it, the retry gets a new one.
        {:ok, %Req.Response{status: 401}} ->
          Auth.invalidate_token(config)

          {:error,
           %DeliveryError{reason: "Bot Connector returned 401", status: 401, retryable?: true}}

        {:ok, %Req.Response{status: status, headers: headers, body: response}} ->
          {:error, DeliveryError.from_http(status, headers, response, "Bot Connector")}

        {:error, reason} ->
          {:error, DeliveryError.from_transport(reason, "Bot Connector")}
      end
    end
  end

  @doc """
  Shows the bot's typing indicator in the participant's conversation (a
  `typing` activity). Teams clears it after a few seconds or with the next
  message, so `isTyping: false` needs no call.
  """
  @impl true
  def send_typing(channel, %{is_typing: true, recipient: recipient}) when is_binary(recipient) do
    config = channel.config || %{}

    with %{} = participant <- Participants.get_participant_by_external_id(channel.id, recipient),
         {:ok, target} <- participant_target(participant),
         :ok <- check_service_url(target.service_url) do
      body = %{
        "type" => "typing",
        "from" => %{"id" => target.bot_id || "28:#{config["app_id"]}"},
        "conversation" => %{"id" => target.conversation_id}
      }

      case post_activity(config, target, body, 5_000) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      nil -> :ok
      {:error, _} = error -> error
    end
  end

  def send_typing(_channel, _signal), do: :ok

  @doc "Checks the app credentials by getting a Bot Framework token."
  @impl true
  def health_probe(channel) do
    case Auth.access_token(channel.config || %{}) do
      {:ok, _token} -> :ok
      {:error, error} -> {:error, DeliveryError.message(error)}
    end
  end

  defp list(value) when is_list(value), do: value
  defp list(_), do: []

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
