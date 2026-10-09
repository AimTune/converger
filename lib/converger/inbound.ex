defmodule Converger.Inbound do
  @moduledoc """
  Receiving a message from a channel.

  Every message a channel brings in takes this path, whatever its transport:
  inbound webhooks (`ConvergerWeb.InboundController`, after the adapter has
  parsed the provider payload) and frames sent by the clients of a
  `websocket` channel (`ConvergerWeb.ConvergerChannel`). The message becomes
  an activity through `Converger.Activities.create_client_activity/2`, so the
  pipeline (middleware of the target channels, routing rules, deliveries and
  retries) applies to it the same way for every channel type.
  """

  require Logger

  alias Converger.{Activities, Conversations, Participants}
  alias Converger.Channels.Channel

  @type message :: map()
  @type result ::
          {:created, Activities.Activity.t()}
          | {:duplicate, Activities.Activity.t()}
          | {:rejected, Ecto.Changeset.t()}
          | {:error, term()}

  @doc "Whether the channel accepts messages (mode `inbound` or `duplex`)."
  def accepts_inbound?(%Channel{mode: mode}), do: mode in ["inbound", "duplex"]

  @doc """
  Turn one message received on `channel` into an activity.

  `message` has the activity client fields (`"type"`, `"text"`,
  `"attachments"`, `"metadata"`), the `"sender"` and optionally an
  `"idempotency_key"` (a stable provider or client message id; a message with
  a known key never creates a second activity) and a `"participant"`
  (`%{"external_id" => ...}`) used to find the conversation.

  ## Options

    * `:conversation_id` - the conversation to write into (tenant-scoped).
      Without it the conversation is the participant's active one on this
      channel (or a new one), or a new participant-less conversation.

  Returns `{:created, activity}`, `{:duplicate, activity}`,
  `{:rejected, changeset}` for a message that can never be accepted, or
  `{:error, reason}` for a request-level or transient failure
  (`:inbound_not_supported`, `:not_found`, `:conversation_closed`, ...).
  """
  @spec receive_message(Channel.t(), message(), keyword()) :: result()
  def receive_message(%Channel{} = channel, message, opts \\ []) do
    if accepts_inbound?(channel) do
      do_receive(channel, message, Keyword.get(opts, :conversation_id))
    else
      {:error, :inbound_not_supported}
    end
  end

  defp do_receive(channel, message, conversation_id) do
    key = message["idempotency_key"]

    case Activities.get_activity_by_channel_idempotency_key(channel.id, key) do
      %Activities.Activity{} = existing ->
        Logger.info("Duplicate inbound message ignored",
          channel_id: channel.id,
          activity_id: existing.id
        )

        {:duplicate, existing}

      nil ->
        case resolve_or_create_conversation(channel, conversation_id, message) do
          {:ok, conversation} ->
            create_activity(channel, conversation, message)

          # e.g. an external id the participant schema rejects: permanent.
          {:error, %Ecto.Changeset{} = changeset} ->
            Logger.warning("Rejected inbound message: invalid participant or conversation",
              channel_id: channel.id,
              errors: inspect(changeset.errors)
            )

            {:rejected, changeset}

          {:error, _} = error ->
            error
        end
    end
  end

  defp create_activity(channel, conversation, message) do
    message = resolve_reference(channel, conversation, message)

    case Activities.create_client_activity(message, %{
           tenant_id: channel.tenant_id,
           conversation_id: conversation.id,
           sender: message["sender"],
           idempotency_key: message["idempotency_key"]
         }) do
      {:ok, activity} ->
        Logger.info("Inbound activity received",
          channel_id: channel.id,
          activity_id: activity.id
        )

        {:created, activity}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("Rejected inbound message",
          channel_id: channel.id,
          errors: inspect(changeset.errors)
        )

        {:rejected, changeset}

      {:error, _} = error ->
        error
    end
  end

  # Adapters name the message a reply or reaction refers to by its provider
  # id ("reply_to_provider_id", e.g. a WhatsApp wamid). It becomes
  # `reply_to_id` when it resolves to a message of this conversation (an
  # inbound one by idempotency key, or an outbound one by its delivery's
  # provider message id). A reaction / edit / delete whose target is unknown
  # (sent before Converger, or in another conversation) is kept as an
  # `event` with its metadata, never dropped. Without a provider id nothing
  # is rewritten (a client sending messageDelete without reply_to_id gets 422); a plain reply simply has no
  # `reply_to_id` (the provider id stays in its metadata).
  defp resolve_reference(channel, conversation, message) do
    {provider_id, message} = Map.pop(message, "reply_to_provider_id")

    target =
      provider_id &&
        Activities.get_activity_by_provider_message_id(channel.id, provider_id)

    reference_type? = message["type"] in Activities.Activity.reference_types()
    explicit_reference? = not is_nil(message["reply_to_id"])

    case target do
      %Activities.Activity{conversation_id: conversation_id, type: target_type, id: id}
      when conversation_id == conversation.id and
             (target_type == "message" or not reference_type?) ->
        Map.put(message, "reply_to_id", id)

      _ when reference_type? and is_binary(provider_id) and not explicit_reference? ->
        Map.put(message, "type", "event")

      _ ->
        message
    end
  end

  # Conversation for an inbound message, in order of precedence:
  #   1. an explicit conversation id (tenant-scoped);
  #   2. the participant's active conversation on this channel, or a new one
  #      for the participant (see Converger.Participants);
  #   3. a new, participant-less conversation (adapters without an external id).
  defp resolve_or_create_conversation(channel, conversation_id, message) do
    cond do
      conversation_id ->
        case Conversations.get_conversation(conversation_id, channel.tenant_id) do
          %Conversations.Conversation{} = conv -> {:ok, conv}
          nil -> {:error, :not_found}
        end

      participant = participant_attrs(message) ->
        Participants.resolve_conversation(channel, participant)

      true ->
        Conversations.create_conversation(%{
          "tenant_id" => channel.tenant_id,
          "channel_id" => channel.id,
          "metadata" => %{"source" => "inbound_webhook"}
        })
    end
  end

  defp participant_attrs(%{"participant" => %{"external_id" => external_id} = participant})
       when is_binary(external_id) and external_id != "",
       do: participant

  defp participant_attrs(_message), do: nil
end
