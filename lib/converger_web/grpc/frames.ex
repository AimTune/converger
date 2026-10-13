defmodule ConvergerWeb.GRPC.Frames do
  @moduledoc """
  The mapping between Converger Protocol v1 frames (the JSON maps of
  docs/protocol/v1.md, built by `ConvergerWeb.Protocol.Frames`) and the
  protobuf messages of `priv/protos/converger/v1/protocol.proto`
  (`Converger.V1.ClientFrame`, `Converger.V1.ServerFrame`).

  The gRPC transport speaks the protocol through this mapping only: client
  frames are turned into the JSON maps the WebSocket endpoint decodes, and
  the session's server frames into protobuf, so both transports run the same
  `ConvergerWeb.Protocol.Session`.

  Rules (docs/protocol/grpc.md has the full table):

    * JSON keys are the protobuf field names in camelCase (`clientId` <->
      `client_id`); a frame's `type` selects the `oneof` case;
    * open-ended JSON (`data` of message types, `metadata`, `meta`,
      `details`, attachments) is a `google.protobuf.Struct`. Struct numbers
      are doubles, so whole numbers come back as integers;
    * a server frame is mapped to its typed message only when the mapping
      is lossless (the typed message maps back to the same frame); every
      other frame (new frame types, unexpected fields) is sent as `raw`, the
      JSON frame as a Struct. A client may send any frame as `raw` too.
  """

  alias Converger.V1.{
    Ack,
    Activity,
    Auth,
    Capabilities,
    ClientFrame,
    Close,
    DeliveryError,
    DeliveryStatus,
    Error,
    Heartbeat,
    Hello,
    Limits,
    MessageSend,
    Ping,
    Presence,
    Read,
    ReplayTruncated,
    ReplyTo,
    Sender,
    ServerFrame,
    Sync,
    TextData,
    TokenRefreshed,
    Typing,
    TypingSignal,
    Welcome
  }

  @transient ~w(welcome ack error deliveryStatus typing presence heartbeat tokenRefreshed replayTruncated)

  ## Server frames

  @doc """
  A server frame (JSON map, atom or string keys) as a `Converger.V1.ServerFrame`.
  Typed when lossless, `raw` otherwise.
  """
  @spec to_server_frame(map()) :: ServerFrame.t()
  def to_server_frame(frame) when is_map(frame) do
    frame = stringify(frame)

    typed =
      try do
        typed_server_frame(frame)
      rescue
        # A value of an unexpected type (e.g. a string seq) cannot be typed.
        _error -> nil
      end

    if typed != nil and lossless?(from_server_frame(typed), frame),
      do: typed,
      else: %ServerFrame{frame: {:raw, to_struct(frame)}}
  end

  @doc "The `Close` frame that ends a stream (gRPC only, section 12.3 close codes)."
  @spec close(pos_integer(), String.t(), nil | non_neg_integer()) :: ServerFrame.t()
  def close(code, reason, retry_after_ms) do
    %ServerFrame{
      frame: {:close, %Close{code: code, reason: reason, retry_after_ms: retry_after_ms}}
    }
  end

  defp typed_server_frame(%{"type" => "welcome", "data" => data}) do
    welcome = %Welcome{
      protocol: data["protocol"],
      compat: data["compat"] || [],
      scope: data["scope"],
      conversation_id: data["conversationId"],
      user_id: data["userId"],
      connection_id: data["connectionId"],
      watermark: data["watermark"],
      pending: Enum.map(data["pending"] || [], &to_struct/1),
      expires_at: data["expiresAt"],
      channel_id: data["channelId"],
      capabilities: capabilities(data["capabilities"]),
      limits: limits(data["limits"])
    }

    server({:welcome, welcome})
  end

  defp typed_server_frame(%{"type" => "ack"} = frame) do
    server(
      {:ack,
       %Ack{
         client_id: frame["clientId"],
         id: frame["id"],
         seq: frame["seq"],
         timestamp: frame["timestamp"],
         duplicate: frame["duplicate"] == true
       }}
    )
  end

  defp typed_server_frame(%{"type" => "error", "data" => data}) do
    server(
      {:error,
       %Error{
         code: data["code"],
         message: data["message"],
         number: data["number"],
         retryable: data["retryable"],
         retry_after_ms: data["retryAfterMs"],
         client_id: data["clientId"],
         frame_type: data["frameType"],
         details: optional_struct(data["details"])
       }}
    )
  end

  defp typed_server_frame(%{"type" => "deliveryStatus", "data" => data}) do
    error =
      case data["error"] do
        %{} = error ->
          %DeliveryError{
            code: error["code"],
            message: error["message"],
            retryable: error["retryable"]
          }

        nil ->
          nil
      end

    server(
      {:delivery_status,
       %DeliveryStatus{
         activity_id: data["activityId"],
         seq: data["seq"],
         up_to_seq: data["upToSeq"],
         channel_id: data["channelId"],
         status: data["status"],
         by: sender(data["by"]),
         attempt: data["attempt"],
         error: error,
         timestamp: data["timestamp"]
       }}
    )
  end

  defp typed_server_frame(%{"type" => "typing"} = frame) do
    server(
      {:typing,
       %Typing{
         is_typing: frame["isTyping"],
         from: frame["from"],
         sender: sender(frame["sender"]),
         seq: frame["seq"],
         id: frame["id"],
         timestamp: frame["timestamp"]
       }}
    )
  end

  defp typed_server_frame(%{"type" => "presence", "data" => data}) do
    server(
      {:presence,
       %Presence{
         participant: sender(data["participant"]),
         status: data["status"],
         connections: data["connections"],
         last_seen_at: data["lastSeenAt"]
       }}
    )
  end

  defp typed_server_frame(%{"type" => "heartbeat"} = frame) do
    server(
      {:heartbeat,
       %Heartbeat{
         timestamp: frame["timestamp"],
         nonce: frame["nonce"],
         head_seq: frame["headSeq"]
       }}
    )
  end

  defp typed_server_frame(%{"type" => "tokenRefreshed", "data" => data}) do
    server({:token_refreshed, %TokenRefreshed{expires_at: data["expiresAt"]}})
  end

  defp typed_server_frame(%{"type" => "replayTruncated", "data" => data}) do
    server(
      {:replay_truncated,
       %ReplayTruncated{watermark: data["watermark"], head_seq: data["headSeq"]}}
    )
  end

  # Persistent frames: text, event, conversationUpdate and message types.
  defp typed_server_frame(%{"type" => type, "seq" => seq} = frame)
       when is_binary(type) and type not in @transient and is_integer(seq) do
    activity = %Activity{
      type: type,
      id: frame["id"],
      seq: seq,
      from: frame["from"],
      sender: sender(frame["sender"]),
      payload: payload(type, frame["data"]),
      timestamp: frame["timestamp"],
      metadata: optional_struct(frame["metadata"]),
      client_id: frame["clientId"],
      reply_to: reply_to(frame["replyTo"]),
      actions: Enum.map(frame["actions"] || [], &to_struct/1)
    }

    server({:activity, activity})
  end

  defp typed_server_frame(_frame), do: nil

  defp server(frame) do
    # Through the wire format, so the lossless check sees what a client decodes
    # (absent proto3 scalars become their defaults).
    %ServerFrame{frame: frame} |> ServerFrame.encode() |> ServerFrame.decode()
  end

  @doc "A `Converger.V1.ServerFrame` as the JSON frame (string keys) it carries."
  @spec from_server_frame(ServerFrame.t()) :: map() | nil
  def from_server_frame(%ServerFrame{frame: frame}), do: server_frame(frame)

  defp server_frame({:raw, struct}), do: from_struct(struct)

  defp server_frame({:welcome, %Welcome{} = w}) do
    # `pending` is required in conversation scope, absent in channel scope.
    pending =
      if w.scope == "channel" and w.pending == [],
        do: nil,
        else: Enum.map(w.pending, &from_struct/1)

    data =
      %{"protocol" => w.protocol, "compat" => w.compat, "connectionId" => w.connection_id}
      |> put("scope", w.scope)
      |> put("conversationId", w.conversation_id)
      |> put("userId", w.user_id)
      |> put("watermark", w.watermark)
      |> put("pending", pending)
      |> put("expiresAt", w.expires_at)
      |> put("channelId", w.channel_id)
      |> put("capabilities", from_capabilities(w.capabilities))
      |> put("limits", from_limits(w.limits))

    %{"type" => "welcome", "data" => data}
  end

  defp server_frame({:activity, %Activity{} = a}) do
    %{
      "type" => a.type,
      "id" => a.id,
      "seq" => a.seq,
      "from" => a.from,
      "timestamp" => a.timestamp,
      "data" => from_payload(a.payload)
    }
    |> put("sender", from_sender(a.sender))
    |> put("metadata", from_optional_struct(a.metadata))
    |> put("clientId", a.client_id)
    |> put("replyTo", from_reply_to(a.reply_to))
    |> put("actions", non_empty(Enum.map(a.actions, &from_struct/1)))
  end

  defp server_frame({:ack, %Ack{} = ack}) do
    %{
      "type" => "ack",
      "clientId" => ack.client_id,
      "id" => ack.id,
      "seq" => ack.seq,
      "timestamp" => ack.timestamp
    }
    |> put("duplicate", if(ack.duplicate, do: true))
  end

  defp server_frame({:error, %Error{} = e}) do
    data =
      %{"code" => e.code, "message" => e.message}
      |> put("number", e.number)
      |> put("retryable", e.retryable)
      |> put("retryAfterMs", e.retry_after_ms)
      |> put("clientId", e.client_id)
      |> put("frameType", e.frame_type)
      |> put("details", from_optional_struct(e.details))

    %{"type" => "error", "data" => data}
  end

  defp server_frame({:delivery_status, %DeliveryStatus{} = d}) do
    error =
      case d.error do
        %DeliveryError{} = error ->
          %{"code" => error.code}
          |> put("message", error.message)
          |> put("retryable", error.retryable)

        nil ->
          nil
      end

    data =
      %{"status" => d.status, "timestamp" => d.timestamp}
      |> put("activityId", d.activity_id)
      |> put("seq", d.seq)
      |> put("upToSeq", d.up_to_seq)
      |> put("channelId", d.channel_id)
      |> put("by", from_sender(d.by))
      |> put("attempt", d.attempt)
      |> put("error", error)

    %{"type" => "deliveryStatus", "data" => data}
  end

  defp server_frame({:typing, %Typing{} = t}) do
    %{"type" => "typing", "isTyping" => t.is_typing}
    |> put("from", t.from)
    |> put("sender", from_sender(t.sender))
    |> put("seq", t.seq)
    |> put("id", t.id)
    |> put("timestamp", t.timestamp)
  end

  defp server_frame({:presence, %Presence{} = p}) do
    data =
      %{"status" => p.status}
      |> put("participant", from_sender(p.participant))
      |> put("connections", p.connections)
      |> put("lastSeenAt", p.last_seen_at)

    %{"type" => "presence", "data" => data}
  end

  defp server_frame({:heartbeat, %Heartbeat{} = h}) do
    %{"type" => "heartbeat", "timestamp" => h.timestamp}
    |> put("nonce", h.nonce)
    |> put("headSeq", h.head_seq)
  end

  defp server_frame({:token_refreshed, %TokenRefreshed{} = t}),
    do: %{"type" => "tokenRefreshed", "data" => %{"expiresAt" => t.expires_at}}

  defp server_frame({:replay_truncated, %ReplayTruncated{} = r}),
    do: %{
      "type" => "replayTruncated",
      "data" => %{"watermark" => r.watermark, "headSeq" => r.head_seq}
    }

  # Not a v1 frame: the stream's close code (gRPC only).
  defp server_frame({:close, %Close{} = c}) do
    %{"type" => "close", "code" => c.code, "reason" => c.reason}
    |> put("retryAfterMs", c.retry_after_ms)
  end

  defp server_frame(nil), do: nil

  ## Client frames

  @doc """
  A `Converger.V1.ClientFrame` as the JSON frame the WebSocket endpoint
  would have decoded. An empty frame (no `oneof` case set) maps to `%{}`,
  which the session answers with `bad_request`.
  """
  @spec from_client_frame(ClientFrame.t()) :: map()
  def from_client_frame(%ClientFrame{frame: frame}), do: client_frame(frame)

  defp client_frame({:hello, %Hello{} = h}) do
    %{"type" => "hello"}
    |> put("protocol", h.protocol)
    |> put("conversationId", h.conversation_id)
    |> put("userId", h.user_id)
    |> put("watermark", position(h.position))
    |> put("token", h.token)
    |> put("meta", from_optional_struct(h.meta))
    |> put("watermarks", if(map_size(h.watermarks) > 0, do: h.watermarks))
    |> put("componentsHash", h.components_hash)
    |> put("tools", non_empty(Enum.map(h.tools, &from_struct/1)))
    |> put("skillsHash", h.skills_hash)
    |> put("skills", non_empty(Enum.map(h.skills, &from_struct/1)))
  end

  defp client_frame({:message, %MessageSend{} = m}) do
    %{"type" => m.type}
    |> put("clientId", m.client_id)
    |> put("data", from_payload(m.payload))
    |> put("metadata", from_optional_struct(m.metadata))
    |> put("meta", from_optional_struct(m.meta))
    |> put("replyTo", from_reply_to(m.reply_to))
    |> put("id", m.id)
    |> put("timestamp", m.timestamp)
  end

  defp client_frame({:typing, %TypingSignal{is_typing: is_typing}}),
    do: %{"type" => "typing", "isTyping" => is_typing}

  defp client_frame({:read, %Read{watermark: watermark}}),
    do: %{"type" => "read", "watermark" => watermark}

  defp client_frame({:sync, %Sync{position: position}}),
    do: put(%{"type" => "sync"}, "watermark", position(position))

  defp client_frame({:ping, %Ping{nonce: nonce}}), do: put(%{"type" => "ping"}, "nonce", nonce)
  defp client_frame({:auth, %Auth{token: token}}), do: %{"type" => "auth", "token" => token}
  defp client_frame({:raw, struct}), do: from_struct(struct)
  defp client_frame(nil), do: %{}

  defp position({:watermark, seq}), do: seq
  defp position({:legacy_watermark, value}), do: value
  defp position(nil), do: nil

  @doc """
  A client frame (JSON map) as a `Converger.V1.ClientFrame`: what a gRPC
  client sends for it. Typed when lossless, `raw` otherwise. Used by the
  conformance tests and Elixir clients.
  """
  @spec to_client_frame(map()) :: ClientFrame.t()
  def to_client_frame(frame) when is_map(frame) do
    frame = stringify(frame)

    typed =
      try do
        typed_client_frame(frame)
      rescue
        _error -> nil
      end

    if typed != nil and lossless?(from_client_frame(typed), frame),
      do: typed,
      else: %ClientFrame{frame: {:raw, to_struct(frame)}}
  end

  defp typed_client_frame(%{"type" => "hello"} = f) do
    client(
      {:hello,
       %Hello{
         protocol: f["protocol"],
         conversation_id: f["conversationId"],
         user_id: f["userId"],
         position: to_position(f["watermark"]),
         token: f["token"],
         meta: optional_struct(f["meta"]),
         watermarks: f["watermarks"] || %{},
         components_hash: f["componentsHash"],
         tools: Enum.map(f["tools"] || [], &to_struct/1),
         skills_hash: f["skillsHash"],
         skills: Enum.map(f["skills"] || [], &to_struct/1)
       }}
    )
  end

  defp typed_client_frame(%{"type" => "typing", "isTyping" => is_typing})
       when is_boolean(is_typing),
       do: client({:typing, %TypingSignal{is_typing: is_typing}})

  defp typed_client_frame(%{"type" => "read", "watermark" => watermark})
       when is_integer(watermark),
       do: client({:read, %Read{watermark: watermark}})

  defp typed_client_frame(%{"type" => "sync"} = f),
    do: client({:sync, %Sync{position: to_position(f["watermark"])}})

  defp typed_client_frame(%{"type" => "ping"} = f), do: client({:ping, %Ping{nonce: f["nonce"]}})

  defp typed_client_frame(%{"type" => "auth", "token" => token}) when is_binary(token),
    do: client({:auth, %Auth{token: token}})

  defp typed_client_frame(%{"type" => type, "data" => data} = f)
       when is_binary(type) and is_map(data) do
    client(
      {:message,
       %MessageSend{
         type: type,
         client_id: f["clientId"],
         payload: payload(type, data),
         metadata: optional_struct(f["metadata"]),
         meta: optional_struct(f["meta"]),
         reply_to: reply_to(f["replyTo"]),
         id: f["id"],
         timestamp: f["timestamp"]
       }}
    )
  end

  defp typed_client_frame(_frame), do: nil

  defp client(frame) do
    %ClientFrame{frame: frame} |> ClientFrame.encode() |> ClientFrame.decode()
  end

  defp to_position(nil), do: nil
  defp to_position(seq) when is_integer(seq) and seq >= 0, do: {:watermark, seq}
  defp to_position(value) when is_binary(value), do: {:legacy_watermark, value}

  ## Shared pieces

  defp capabilities(nil), do: nil

  defp capabilities(%{} = caps) do
    %Capabilities{
      acks: caps["acks"],
      receipts: caps["receipts"],
      presence: caps["presence"],
      typing: caps["typing"],
      regenerate: caps["regenerate"],
      edit: caps["edit"],
      message_types: caps["messageTypes"] || []
    }
  end

  defp limits(nil), do: nil

  defp limits(%{} = limits) do
    %Limits{
      max_frame_bytes: limits["maxFrameBytes"],
      max_text_bytes: limits["maxTextBytes"],
      max_metadata_bytes: limits["maxMetadataBytes"],
      max_in_flight: limits["maxInFlight"],
      heartbeat_interval_ms: limits["heartbeatIntervalMs"],
      idle_timeout_ms: limits["idleTimeoutMs"],
      replay_batch: limits["replayBatch"],
      replay_max: limits["replayMax"],
      max_conversations: limits["maxConversations"]
    }
  end

  defp from_capabilities(nil), do: nil

  defp from_capabilities(%Capabilities{} = caps) do
    compact(%{
      "acks" => caps.acks,
      "receipts" => caps.receipts,
      "presence" => caps.presence,
      "typing" => caps.typing,
      "regenerate" => caps.regenerate,
      "edit" => caps.edit,
      "messageTypes" => non_empty(caps.message_types)
    })
  end

  defp from_limits(nil), do: nil

  defp from_limits(%Limits{} = limits) do
    compact(%{
      "maxFrameBytes" => limits.max_frame_bytes,
      "maxTextBytes" => limits.max_text_bytes,
      "maxMetadataBytes" => limits.max_metadata_bytes,
      "maxInFlight" => limits.max_in_flight,
      "heartbeatIntervalMs" => limits.heartbeat_interval_ms,
      "idleTimeoutMs" => limits.idle_timeout_ms,
      "replayBatch" => limits.replay_batch,
      "replayMax" => limits.replay_max,
      "maxConversations" => limits.max_conversations
    })
  end

  defp payload("text", %{"text" => text} = data) when is_binary(text) do
    case Map.keys(data) -- ["text", "attachments"] do
      [] ->
        case data["attachments"] do
          nil ->
            {:text, %TextData{text: text}}

          [%{} | _] = attachments ->
            {:text, %TextData{text: text, attachments: Enum.map(attachments, &to_struct/1)}}

          _ ->
            {:data, to_struct(data)}
        end

      _ ->
        {:data, to_struct(data)}
    end
  end

  defp payload(_type, %{} = data), do: {:data, to_struct(data)}
  defp payload(_type, nil), do: nil

  defp from_payload({:text, %TextData{text: text, attachments: []}}), do: %{"text" => text}

  defp from_payload({:text, %TextData{text: text, attachments: attachments}}),
    do: %{"text" => text, "attachments" => Enum.map(attachments, &from_struct/1)}

  defp from_payload({:data, struct}), do: from_struct(struct)
  defp from_payload(nil), do: nil

  defp sender(%{"id" => id} = sender),
    do: %Sender{id: id, role: sender["role"], name: sender["name"]}

  defp sender(nil), do: nil

  defp from_sender(%Sender{} = s),
    do: %{"id" => s.id} |> put("role", s.role) |> put("name", s.name)

  defp from_sender(nil), do: nil

  defp reply_to(%{"id" => id} = reply_to), do: %ReplyTo{id: id, seq: reply_to["seq"]}
  defp reply_to(nil), do: nil

  defp from_reply_to(%ReplyTo{id: id, seq: seq}), do: put(%{"id" => id}, "seq", seq)
  defp from_reply_to(nil), do: nil

  defp optional_struct(nil), do: nil
  defp optional_struct(%{} = map), do: to_struct(map)

  defp from_optional_struct(nil), do: nil
  defp from_optional_struct(struct), do: from_struct(struct)

  @doc "A JSON object as a `google.protobuf.Struct`."
  @spec to_struct(map()) :: Google.Protobuf.Struct.t()
  def to_struct(map) when is_map(map), do: map |> stringify() |> Google.Protobuf.from_map()

  @doc """
  A `google.protobuf.Struct` as a JSON object. Struct numbers are doubles:
  whole numbers that fit a JSON-safe integer come back as integers.
  """
  @spec from_struct(Google.Protobuf.Struct.t()) :: map()
  def from_struct(%Google.Protobuf.Struct{} = struct),
    do: struct |> Google.Protobuf.to_map() |> integers()

  @max_safe 9_007_199_254_740_991

  defp integers(%{} = map), do: Map.new(map, fn {k, v} -> {k, integers(v)} end)
  defp integers(list) when is_list(list), do: Enum.map(list, &integers/1)

  defp integers(float) when is_float(float) and float == trunc(float) and abs(float) <= @max_safe,
    do: trunc(float)

  defp integers(value), do: value

  @doc "A frame with string keys throughout (frames are built with atom keys in places)."
  @spec stringify(term()) :: term()
  def stringify(%{__struct__: _} = struct), do: struct
  def stringify(%{} = map), do: Map.new(map, fn {k, v} -> {key(k), stringify(v)} end)
  def stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  def stringify(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  def stringify(value), do: value

  defp key(key) when is_binary(key), do: key
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: to_string(key)

  # `==` compares numbers by value (1 == 1.0), as JSON does.
  defp lossless?(mapped, frame), do: mapped == frame

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp compact(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp non_empty([]), do: nil
  defp non_empty(list), do: list
end
