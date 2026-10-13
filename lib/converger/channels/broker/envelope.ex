defmodule Converger.Channels.Broker.Envelope do
  @moduledoc """
  The JSON envelope of broker channel messages (`kafka`, `rabbitmq`, `nats`,
  `redis_streams`).

  ## Outbound (`topic_out`, exchange)

  The canonical activity (`Converger.Activities.Serializer.canonical/1`, the
  body of outbound webhooks and of WebSocket frames) plus the broker
  channel's `channel_id` and an `event` name. `tenant_id` and
  `conversation_id` are canonical fields already:

      {
        "event": "activity.created",
        "channel_id": "…",
        "tenant_id": "…",
        "conversation_id": "…",
        "id": "…", "type": "message", "sender": "agent-7", "text": "Hi",
        "attachments": [], "metadata": {}, "seq": 2, "reply_to_id": null,
        "idempotency_key": null, "edited_at": null, "deleted_at": null,
        "inserted_at": "2026-10-12T09:00:00.000000Z"
      }

  ## Inbound (`topic_in`, queue)

  The same shape. Only the activity client fields (`type`, `text`,
  `attachments`, `metadata`, `reply_to_id`) are taken from it, plus:

    * `sender` - stored as the activity sender (default: the participant's
      `external_id`, else `"external"`);
    * `conversation_id` - optional; the conversation to write into (of the
      channel's tenant). Without it the conversation is the participant's
      active one on the channel, or a new one;
    * `participant` - optional `{"external_id": "...", "display_name": "..."}`,
      so messages of one external party share their open conversation;
    * `idempotency_key` - optional; when absent the broker message id is the
      idempotency key (`Converger.Channels.Broker.idempotency_key/3`);
    * `tenant_id`, `channel_id` - optional; when present they must be the
      consuming channel's, so a message produced for another channel or
      tenant is dead-lettered instead of being accepted.

  Server-controlled canonical fields (`id`, `seq`, `inserted_at`, ...) are
  ignored, so an outbound envelope can be fed back as is.
  """

  alias Converger.Activities.{Activity, Serializer}

  @event "activity.created"

  @typedoc "A decoded inbound envelope."
  @type inbound :: %{
          message: map(),
          conversation_id: String.t() | nil,
          idempotency_key: String.t() | nil
        }

  @doc "The outbound envelope of `activity` delivered to `channel`, as a map."
  @spec outbound(Activity.t(), map()) :: map()
  def outbound(%Activity{} = activity, channel) do
    activity
    |> Serializer.canonical()
    |> Map.put(:channel_id, Map.get(channel, :id))
    |> Map.put(:tenant_id, activity.tenant_id || Map.get(channel, :tenant_id))
    |> Map.put(:event, @event)
  end

  @doc "The outbound envelope of `activity` delivered to `channel`, as JSON."
  @spec encode(Activity.t(), map()) :: binary()
  def encode(%Activity{} = activity, channel), do: Jason.encode!(outbound(activity, channel))

  @doc """
  Decode an inbound message body consumed by `channel` into the message
  `Converger.Inbound.receive_message/3` takes.

  Returns `{:ok, inbound}` or `{:error, reason}`; an error is permanent (the
  same bytes never decode), so the message is dead-lettered.
  """
  @spec decode(binary(), map()) :: {:ok, inbound()} | {:error, String.t()}
  def decode(payload, channel) when is_binary(payload) do
    with {:ok, %{} = env} <- json(payload),
         :ok <- same("tenant_id", env, Map.get(channel, :tenant_id)),
         :ok <- same("channel_id", env, Map.get(channel, :id)),
         {:ok, conversation_id} <- conversation_id(env["conversation_id"]),
         {:ok, participant} <- participant(env["participant"]),
         {:ok, message} <- message(env, participant) do
      {:ok,
       %{
         message: message,
         conversation_id: conversation_id,
         idempotency_key: non_empty(env["idempotency_key"])
       }}
    end
  end

  def decode(nil, _channel), do: {:error, "message has no payload"}
  def decode(_payload, _channel), do: {:error, "message body is not a binary"}

  defp json(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = env} -> {:ok, env}
      {:ok, _other} -> {:error, "message body is not a JSON object"}
      {:error, _} -> {:error, "message body is not valid JSON"}
    end
  end

  defp same(key, env, expected) do
    case Map.get(env, key) do
      nil -> :ok
      ^expected -> :ok
      _other -> {:error, "#{key} does not match the consuming channel"}
    end
  end

  defp conversation_id(nil), do: {:ok, nil}

  defp conversation_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "conversation_id is not a UUID"}
    end
  end

  defp conversation_id(_), do: {:error, "conversation_id is not a UUID"}

  defp participant(nil), do: {:ok, nil}

  defp participant(%{"external_id" => external_id} = participant)
       when is_binary(external_id) and external_id != "" do
    {:ok,
     %{
       "external_id" => external_id,
       "display_name" => string_or_nil(participant["display_name"])
     }}
  end

  defp participant(_), do: {:error, "participant must be an object with an external_id string"}

  defp message(env, participant) do
    message = %{
      "type" => env["type"] || "message",
      "text" => env["text"],
      "attachments" => env["attachments"] || [],
      "metadata" => env["metadata"] || %{},
      "reply_to_id" => string_or_nil(env["reply_to_id"]),
      "sender" => env["sender"] || (participant && participant["external_id"]) || "external",
      "participant" => participant
    }

    case Enum.find(checks(), fn {valid?, _error} -> not valid?.(message) end) do
      nil -> {:ok, message}
      {_valid?, error} -> {:error, error}
    end
  end

  # Shape checks of an inbound message, in order; the first failing one is
  # the error. (Values the activity schema checks, such as known types or
  # attachment fields, are left to it.)
  defp checks do
    [
      {&is_binary(&1["type"]), "type must be a string"},
      {&(is_nil(&1["text"]) or is_binary(&1["text"])), "text must be a string"},
      {&is_list(&1["attachments"]), "attachments must be a list"},
      {&is_map(&1["metadata"]), "metadata must be an object"},
      {&(is_binary(&1["sender"]) and &1["sender"] != ""), "sender must be a non-empty string"},
      {&(&1["type"] != "message" or not blank?(&1["text"]) or &1["attachments"] != []),
       "message has neither text nor attachments"}
    ]
  end

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_), do: nil

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil
end
