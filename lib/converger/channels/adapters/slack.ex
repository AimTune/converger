defmodule Converger.Channels.Adapters.Slack do
  @moduledoc """
  Slack channel adapter: Events API inbound, Web API outbound.

    * Inbound - Slack posts Events API callbacks (and, for card buttons,
      Block Kit interactions) to `POST /api/v1/channels/:id/inbound`. Each
      request is verified with the app's signing secret (`X-Slack-Signature`,
      timestamp within the tolerance window), the `url_verification`
      handshake is answered with its `challenge`, and events are parsed by
      `Converger.Channels.Adapters.Slack.Events`.
    * Outbound - `message` activities are posted with `chat.postMessage`
      (card attachments as Block Kit, files through `files.uploadV2`),
      `messageUpdate` / `messageDelete` with `chat.update` / `chat.delete`.

  Replies go to the Slack channel and thread of the conversation's
  participant (see `Converger.Channels.Adapters.Slack.Events` for the
  conversation scopes), or to the channel config's default `channel`.
  Activity metadata `slack_channel` / `slack_thread_ts` override both.

  See `docs/channels/slack.md`.
  """

  use Converger.Channels.Adapter, type: "slack"

  alias Converger.Activities.Activity
  alias Converger.Channels.Adapters.Slack.{Api, Blocks, Events, Files}
  alias Converger.Channels.{DeliveryError, InboundSignature}
  alias Converger.Deliveries
  alias Converger.Participants
  alias Converger.Pipeline.RetryPolicy
  alias Converger.Repo

  @ts_format ~r/\A\d+\.\d+\z/

  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :provider_ack,
      :media,
      :edits,
      activity_types: ~w(message messageUpdate messageDelete)
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
        label: "Bot token",
        placeholder: "xoxb-...",
        help: "Bot User OAuth Token of the Slack app"
      },
      %{
        name: "signing_secret",
        type: :string,
        required: true,
        secret: true,
        label: "Signing secret",
        placeholder: "Verifies X-Slack-Signature"
      },
      %{
        name: "channel",
        type: :string,
        label: "Default channel",
        placeholder: "e.g. C0123456789",
        help: "Where messages go when the conversation has no Slack participant",
        summary: true
      },
      %{
        name: "app_id",
        type: :string,
        label: "App ID",
        placeholder: "e.g. A0123456789",
        help: "When set, events of other Slack apps are ignored"
      },
      %{
        name: "conversation_scope",
        type: :string,
        label: "Conversation scope",
        placeholder: "thread",
        help: "thread (default), channel or user: what one conversation is"
      },
      %{
        name: "download_files",
        type: :boolean,
        label: "Download inbound files",
        help: "Store files shared in Slack as Converger uploads"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    cond do
      not String.starts_with?(config["bot_token"], "xoxb-") ->
        {:error, "slack config 'bot_token' must be a bot token (xoxb-...)"}

      config["conversation_scope"] not in [nil, "" | Events.scopes()] ->
        {:error,
         "slack config 'conversation_scope' must be one of: #{Enum.join(Events.scopes(), ", ")}"}

      true ->
        :ok
    end
  end

  @impl true
  def retry_policy, do: %{timeout_ms: 10_000}

  ## Outbound

  @impl true
  def deliver_activity(channel, %{type: "messageUpdate"} = activity) do
    with {:ok, ref} <- own_message(channel, activity, "edit"),
         {:ok, _body} <-
           Api.call(
             channel,
             "chat.update",
             put_blocks(%{channel: ref.channel, ts: ref.ts, text: activity.text || ""}, activity),
             timeout: timeout(channel)
           ) do
      {:ok, %{"slack_channel" => ref.channel, "slack_ts" => ref.ts}}
    end
  end

  def deliver_activity(channel, %{type: "messageDelete"} = activity) do
    with {:ok, ref} <- own_message(channel, activity, "delete"),
         {:ok, _body} <-
           Api.call(channel, "chat.delete", %{channel: ref.channel, ts: ref.ts},
             timeout: timeout(channel)
           ) do
      {:ok, %{"slack_channel" => ref.channel, "slack_ts" => ref.ts}}
    end
  end

  def deliver_activity(channel, activity) do
    with {:ok, slack_channel, thread_ts} <- target(channel, activity),
         {:ok, files} <- Files.prepare(channel, activity),
         {:ok, posted} <- post_message(channel, activity, slack_channel, thread_ts, files),
         {:ok, _shared} <- Files.share(channel, files, slack_channel, thread_ts) do
      meta =
        %{
          "slack_channel" => slack_channel,
          "slack_ts" => posted["ts"],
          "slack_thread_ts" => thread_ts,
          "provider_message_id" => Events.message_ref(slack_channel, posted["ts"]),
          "slack_file_ids" => if(files != [], do: Enum.map(files, & &1["id"]))
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      {:ok, meta}
    end
  end

  # A message with only files is shared by files.completeUploadExternal alone.
  defp post_message(channel, activity, slack_channel, thread_ts, files) do
    payload =
      %{channel: slack_channel, text: activity.text || ""}
      |> put_blocks(activity)
      |> then(fn payload ->
        if thread_ts, do: Map.put(payload, :thread_ts, thread_ts), else: payload
      end)

    if payload.text == "" and not Map.has_key?(payload, :blocks) and files != [] do
      {:ok, %{}}
    else
      Api.call(channel, "chat.postMessage", payload, timeout: timeout(channel))
    end
  end

  defp put_blocks(payload, activity) do
    case Blocks.from_attachments(activity.attachments) do
      [] -> payload
      blocks -> Map.put(payload, :blocks, blocks)
    end
  end

  # Where a message goes, in order of precedence: activity metadata, the
  # conversation's Slack participant, the thread of the activity it replies
  # to, the channel config's default `channel`.
  defp target(channel, activity) do
    metadata = activity.metadata || %{}
    {participant_channel, participant_thread} = participant_target(channel, activity)
    {reply_channel, reply_thread} = reply_target(channel, activity)

    slack_channel =
      first_present([
        metadata["slack_channel"],
        participant_channel,
        reply_channel,
        (channel.config || %{})["channel"]
      ])

    # The thread of the replied-to message only applies in its own channel.
    reply_thread = if reply_channel == slack_channel, do: reply_thread
    thread_ts = first_present([metadata["slack_thread_ts"], participant_thread, reply_thread])

    if slack_channel, do: {:ok, slack_channel, thread_ts}, else: {:error, no_channel_error()}
  end

  defp no_channel_error do
    DeliveryError.permanent(
      "no Slack channel: set the channel config 'channel', activity metadata 'slack_channel', " <>
        "or reply in a conversation with a participant on this channel"
    )
  end

  # The channel and thread root of the message an activity replies to.
  defp reply_target(_channel, %{reply_to_id: nil}), do: {nil, nil}

  defp reply_target(channel, %{reply_to_id: reply_to_id}) do
    case reference(channel, reply_to_id) do
      %{channel: slack_channel} = ref -> {slack_channel, ref.thread_ts || ref.ts}
      nil -> {nil, nil}
    end
  end

  defp first_present(values), do: Enum.find_value(values, &present/1)

  # The participant's external_id is "<channel>", "<channel>:<thread ts>" or
  # "<channel>:<user>" (Events.scope/1).
  defp participant_target(channel, activity) do
    case Participants.recipient_for(activity, Map.get(channel, :id)) do
      nil ->
        {nil, nil}

      external_id ->
        case String.split(external_id, ":", parts: 2) do
          [slack_channel, ts] -> {slack_channel, if(ts =~ @ts_format, do: ts)}
          [slack_channel] -> {slack_channel, nil}
        end
    end
  end

  # The Slack message an edit or delete targets: one Converger posted (Slack
  # only lets a bot edit or delete its own messages).
  defp own_message(channel, %{reply_to_id: target_id}, action) when is_binary(target_id) do
    case Deliveries.get_delivery_for_activity_and_channel(target_id, channel.id) do
      %{provider_message_id: ref} = delivery when is_binary(ref) ->
        {:ok, parse_ref(ref, delivery.metadata)}

      _ ->
        {:error,
         DeliveryError.permanent(
           "cannot #{action} a message that was not posted to Slack by this channel"
         )}
    end
  end

  defp own_message(_channel, _activity, action),
    do: {:error, DeliveryError.permanent("cannot #{action}: no reply_to_id")}

  # A Slack message an activity corresponds to on `channel`: an outbound one
  # (its delivery's provider message id) or an inbound one (its idempotency
  # key), with its thread root.
  defp reference(channel, activity_id) do
    case Deliveries.get_delivery_for_activity_and_channel(activity_id, channel.id) do
      %{provider_message_id: ref} = delivery when is_binary(ref) ->
        parse_ref(ref, delivery.metadata)

      _ ->
        case Repo.get(Activity, activity_id) do
          %Activity{idempotency_key: key, metadata: %{"slack_channel" => _} = metadata}
          when is_binary(key) ->
            parse_ref(key, metadata)

          _ ->
            nil
        end
    end
  end

  defp parse_ref(ref, metadata) do
    case String.split(ref, ":") do
      [slack_channel, ts | _] ->
        %{
          channel: slack_channel,
          ts: ts,
          thread_ts: present((metadata || %{})["slack_thread_ts"])
        }

      _ ->
        nil
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp timeout(channel), do: RetryPolicy.for_channel(channel).timeout_ms

  ## Inbound

  @impl true
  def parse_inbound(channel, params) do
    with {:ok, messages} <- Events.parse(channel, params) do
      if download_files?(channel),
        do: {:ok, Enum.map(messages, &rehost_files(channel, &1))},
        else: {:ok, messages}
    end
  end

  defp download_files?(channel), do: (channel.config || %{})["download_files"] in [true, "true"]

  defp rehost_files(channel, %{"attachments" => [_ | _] = attachments} = message),
    do: %{message | "attachments" => Files.rehost(channel, attachments)}

  defp rehost_files(_channel, message), do: message

  @doc """
  Answers Slack's `url_verification` request (sent when the Request URL is
  saved in the app settings) with its `challenge`. It is signed like every
  other request, so it is answered only after the signature is verified.
  """
  @impl true
  def inbound_challenge(_channel, %{"type" => "url_verification", "challenge" => challenge})
      when is_binary(challenge),
      do: {:ok, %{"challenge" => challenge}}

  def inbound_challenge(_channel, _params), do: :none

  @doc """
  Verifies Slack's request signature: `X-Slack-Signature: v0=<hex
  HMAC-SHA256 of "v0:<timestamp>:<raw body>", keyed with the signing
  secret>`, with `X-Slack-Request-Timestamp` within
  `Converger.Channels.InboundSignature.tolerance_seconds/0` (300 s by
  default) of the server clock, so a captured request cannot be replayed
  later.

  Returns `:missing` when the signature header is absent (or no signing
  secret is configured), so the controller applies the channel's
  `require_signature` policy.
  """
  @impl true
  def verify_inbound_signature(channel, headers, raw_body) do
    secret = (channel.config || %{})["signing_secret"]

    case InboundSignature.get_header(headers, "x-slack-signature") do
      nil ->
        :missing

      _signature when not is_binary(secret) or secret == "" ->
        :missing

      signature ->
        with {:ok, timestamp} <- request_timestamp(headers) do
          expected = "v0=" <> InboundSignature.hmac_hex(secret, "v0:#{timestamp}:#{raw_body}")

          if Plug.Crypto.secure_compare(expected, String.downcase(signature)),
            do: :ok,
            else: {:error, :invalid_signature}
        end
    end
  end

  defp request_timestamp(headers) do
    with value when is_binary(value) <-
           InboundSignature.get_header(headers, "x-slack-request-timestamp"),
         {timestamp, ""} <- Integer.parse(value) do
      if abs(System.system_time(:second) - timestamp) <= InboundSignature.tolerance_seconds(),
        do: {:ok, timestamp},
        else: {:error, :stale_timestamp}
    else
      _ -> {:error, :invalid_timestamp}
    end
  end

  @doc "Calls `auth.test`: checks that the bot token is valid and not revoked."
  @impl true
  def health_probe(channel) do
    case Api.call(channel, "auth.test", %{}, timeout: 5_000) do
      {:ok, _body} -> :ok
      {:error, error} -> {:error, DeliveryError.message(error)}
    end
  end
end
