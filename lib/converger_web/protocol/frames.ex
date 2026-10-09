defmodule ConvergerWeb.Protocol.Frames do
  @moduledoc """
  Builds Converger Protocol v1 server frames (docs/protocol/v1.md).

  Frames are plain maps with string keys, so every transport and encoding
  (`ConvergerWeb.Protocol.Codec`) sends exactly the same content. Activities
  are mapped from the canonical activity (`Converger.Activities.Serializer`),
  the same source as REST and the Phoenix channel frames (section 5.4).
  """

  alias Converger.Activities.{Activity, Downgrade, Serializer}
  alias ConvergerWeb.Protocol

  # code => {number, retryable} (section 12.2)
  @errors %{
    "bad_request" => {1000, false},
    "no_session" => {1001, false},
    "unsupported_protocol" => {1002, false},
    "invalid_watermark" => {1003, false},
    "invalid_message" => {1004, false},
    "unauthorized" => {2000, false},
    "token_expired" => {2001, true},
    "forbidden" => {2002, false},
    "channel_inactive" => {2003, false},
    "rate_limited" => {3000, true},
    "payload_too_large" => {3001, false},
    "too_many_in_flight" => {3002, true},
    "too_many_subscriptions" => {3003, false},
    "conversation_closed" => {4000, false},
    "conversation_not_found" => {4001, false},
    "bot_unavailable" => {5004, true},
    "internal" => {9000, true},
    "unavailable" => {9001, true}
  }

  @doc """
  The persistent frame for an activity, as seen by the end user `user_id`.

  `from` and `sender.role` are relative to that user (section 5.1): their own
  activities are `user`, lifecycle activities are `system`, every other party
  is `bot`. `live?` is false for replayed frames (it only affects legacy
  persisted `typing` activities).
  """
  def activity(activity, user_id, live? \\ true)

  def activity(%Activity{} = activity, user_id, live?),
    do: activity |> Serializer.canonical() |> activity(user_id, live?)

  def activity(%{} = canonical, user_id, live?) do
    role = role(canonical.sender, user_id)

    base = %{
      "id" => canonical.id,
      "seq" => canonical.seq,
      "from" => if(role == "user", do: "user", else: "bot"),
      "sender" => %{"id" => sender_id(canonical.sender), "role" => role}
    }

    typed(canonical.type, canonical, base, role, live?)
  end

  defp typed("typing", _canonical, base, _role, live?) do
    Map.merge(base, %{"type" => "typing", "isTyping" => live?})
  end

  defp typed("conversationUpdate", canonical, base, _role, _live?) do
    base
    |> Map.merge(%{"type" => "conversationUpdate", "data" => canonical.metadata || %{}})
    |> put_timestamp(canonical)
  end

  defp typed("endOfConversation", canonical, base, _role, _live?) do
    base
    |> Map.merge(%{
      "type" => "conversationUpdate",
      "data" => %{"event" => "conversation_ended", "status" => "closed"}
    })
    |> put_timestamp(canonical)
  end

  # Reactions, edits and deletes (#28) until their own frames are specified
  # (#68): an `event` named after the activity type, whose `text` is the
  # plain-text fallback and whose `value` names the referenced activity.
  defp typed(type, canonical, base, _role, _live?)
       when type in ["messageReaction", "messageUpdate", "messageDelete"] do
    value =
      %{"replyToId" => canonical.reply_to_id}
      |> maybe_put("text", canonical.text)
      |> maybe_put("attachments", non_empty(canonical.attachments))

    base
    |> Map.merge(%{
      "type" => "event",
      "data" => %{
        "name" => type,
        "text" => Downgrade.text(canonical) || "",
        "value" => value
      }
    })
    |> put_timestamp(canonical)
    |> put_metadata(canonical.metadata || %{})
  end

  defp typed("event", canonical, base, _role, _live?) do
    metadata = canonical.metadata || %{}

    data =
      %{"text" => canonical.text || ""}
      |> maybe_put("name", metadata["name"])
      |> maybe_put("value", metadata["value"])

    base
    |> Map.merge(%{"type" => "event", "data" => data})
    |> put_timestamp(canonical)
    |> put_metadata(metadata)
  end

  # "message" and anything unknown: the text envelope.
  defp typed(_type, canonical, base, role, _live?) do
    data =
      case canonical.attachments do
        [_ | _] = attachments -> %{"text" => canonical.text || "", "attachments" => attachments}
        _ -> %{"text" => canonical.text || ""}
      end

    base
    |> Map.merge(%{"type" => "text", "data" => data})
    |> put_timestamp(canonical)
    |> put_metadata(canonical.metadata)
    |> put_reply_to(Map.get(canonical, :reply_to_id))
    |> put_client_id(role, canonical.sender, canonical.idempotency_key)
  end

  defp role("system", _user_id), do: "system"
  defp role(sender, user_id) when is_binary(user_id) and sender == user_id, do: "user"
  defp role(_sender, _user_id), do: "bot"

  defp sender_id(sender) when is_binary(sender) and sender != "", do: sender
  defp sender_id(_sender), do: "unknown"

  defp put_timestamp(frame, canonical),
    do: Map.put(frame, "timestamp", Protocol.to_ms(canonical.inserted_at))

  defp put_metadata(frame, metadata) when is_map(metadata) and map_size(metadata) > 0,
    do: Map.put(frame, "metadata", metadata)

  defp put_metadata(frame, _metadata), do: frame

  # The sender's other connections de-duplicate their own turns by clientId.
  # Only keys stored by a WebSocket send of this sender (`client_key/2`) are
  # client ids; REST keys and provider message ids are never exposed.
  defp put_client_id(frame, "user", sender, key) when is_binary(key) do
    prefix = client_key(sender, "")

    client_id =
      if String.starts_with?(key, prefix),
        do: binary_part(key, byte_size(prefix), byte_size(key) - byte_size(prefix))

    if Protocol.client_id?(client_id), do: Map.put(frame, "clientId", client_id), else: frame
  end

  defp put_client_id(frame, _role, _sender, _key), do: frame

  @doc """
  The idempotency key a WebSocket send with `client_id` is stored under:
  `ws:<sender>:<clientId>`, shared by the native endpoint and the Phoenix
  binding's `postActivity`.
  """
  def client_key(sender, client_id), do: "ws:#{sender}:#{client_id}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty([_ | _] = list), do: list
  defp non_empty(_), do: nil

  # A threaded reply names the activity it answers (`replyTo`, section 5.3).
  defp put_reply_to(frame, nil), do: frame
  defp put_reply_to(frame, id), do: Map.put(frame, "replyTo", %{"id" => id})

  @doc "The `ack` for a persisted send (section 7)."
  def ack(%Activity{} = activity, client_id, duplicate?) do
    frame = %{
      "type" => "ack",
      "clientId" => client_id,
      "id" => activity.id,
      "seq" => activity.seq,
      "timestamp" => Protocol.to_ms(activity.inserted_at)
    }

    if duplicate?, do: Map.put(frame, "duplicate", true), else: frame
  end

  @doc """
  An `error` frame (section 12). Options: `:client_id`, `:frame_type`,
  `:details`, `:retry_after_ms`.
  """
  def error(code, message, opts \\ []) do
    {number, retryable} = Map.fetch!(@errors, code)

    data =
      %{"code" => code, "message" => message, "number" => number, "retryable" => retryable}
      |> maybe_put("clientId", opts[:client_id])
      |> maybe_put("frameType", opts[:frame_type])
      |> maybe_put("details", opts[:details])
      |> maybe_put("retryAfterMs", opts[:retry_after_ms])

    %{"type" => "error", "data" => data}
  end

  @doc "The `welcome` frame (section 4)."
  def welcome(fields) do
    %{
      "type" => "welcome",
      "data" => %{
        "protocol" => Protocol.version(),
        "compat" => Protocol.compat(),
        "scope" => "conversation",
        "conversationId" => fields.conversation_id,
        "userId" => fields.user_id,
        "connectionId" => fields.connection_id,
        "watermark" => fields.watermark,
        "pending" => [],
        "expiresAt" => fields.expires_at,
        "capabilities" => %{
          "acks" => true,
          "receipts" => true,
          "presence" => Map.get(fields, :presence, false),
          "typing" => true,
          "regenerate" => false,
          "edit" => false
        },
        "limits" => Protocol.limits()
      }
    }
  end

  @doc "A `heartbeat` frame (section 8.5)."
  def heartbeat(head_seq, nonce \\ nil) do
    %{"type" => "heartbeat", "timestamp" => Protocol.to_ms(nil), "headSeq" => head_seq}
    |> maybe_put("nonce", if(is_binary(nonce), do: nonce))
  end

  @doc "A `replayTruncated` frame (section 6.2)."
  def replay_truncated(watermark, head_seq) do
    %{"type" => "replayTruncated", "data" => %{"watermark" => watermark, "headSeq" => head_seq}}
  end

  @doc "A `tokenRefreshed` frame (section 3.3)."
  def token_refreshed(expires_at) do
    %{"type" => "tokenRefreshed", "data" => %{"expiresAt" => expires_at}}
  end

  @doc """
  Validation errors of a changeset, per field, for `error.data.details`: the
  same map the REST API returns as `errors` (HTTP 422).
  """
  def changeset_details(%Ecto.Changeset{} = changeset) do
    ConvergerWeb.ErrorJSON.render("error.json", %{changeset: changeset}).errors
  end
end
