defmodule ConvergerWeb.Protocol.Send do
  @moduledoc """
  Parsing of client sends (user turns) of Converger Protocol v1
  (docs/protocol/v1.md, section 7), shared by the native endpoint
  (`ConvergerWeb.ProtocolSocket`) and the Phoenix binding
  (`ConvergerWeb.ConvergerChannel`, event `frame`).

  A send is a message frame: `{"type": "text", "clientId": "c-17", "data":
  {"text": "..."}, "metadata": {...}}`, or any rich message type of
  docs/protocol/messages.md (`{"type": "location", "data": {...}}`). Errors are returned as
  `{:error, code, message, opts}`, ready for `ConvergerWeb.Protocol.Frames.error/3`.
  """

  alias Converger.Activities.MessagePayload
  alias ConvergerWeb.Protocol

  # Reserved frame types that are not client frames (section 5.5).
  @reserved ~w(welcome resume genui_event client_tools client_skills abort tool_call skill
               skills genui genui_components interrupt interrupt_resolved run error typing
               survey regenerate edit ack deliveryStatus presence conversationUpdate
               endOfConversation event heartbeat ping read sync auth tokenRefreshed
               replayTruncated subscribe unsubscribe subscribed unsubscribed message
               activity activitySet frame hello)

  @message_type ~r/^[a-z][a-z0-9_-]{0,63}$/

  @doc """
  What a client frame type is, once the transport has handled its own
  protocol frames: `:text` (a send), `:reserved` (a protocol frame type that
  is not a client frame here), `:rich` (a rich message type, stored as a typed message, #68) or `:unknown`.
  """
  def kind("text"), do: :text
  def kind(type) when type in @reserved, do: :reserved

  def kind(type) when is_binary(type),
    do: if(Regex.match?(@message_type, type), do: :rich, else: :unknown)

  def kind(_type), do: :unknown

  @doc """
  The send's clientId: `clientId` wins; without one a mekik/1 `id` is used
  when it has the clientId syntax, and ignored otherwise (no ack). Returns
  `{:ok, client_id | nil}` or `{:error, "bad_request", message, []}`.
  """
  def client_id(%{"clientId" => client_id}) when client_id != nil do
    if Protocol.client_id?(client_id),
      do: {:ok, client_id},
      else: {:error, "bad_request", "invalid clientId", []}
  end

  def client_id(%{"id" => id}) do
    if Protocol.client_id?(id), do: {:ok, id}, else: {:ok, nil}
  end

  def client_id(_frame), do: {:ok, nil}

  @doc """
  The activity's client params (`Converger.Activities.Activity.client_fields/0`)
  of a `text` frame.
  """
  def message_params(%{"type" => "text", "data" => %{"text" => text}} = frame, client_id)
      when is_binary(text) do
    with {:ok, metadata} <- metadata(frame, client_id) do
      case MessagePayload.from_frame(frame) do
        :plain -> plain_params(frame, metadata, client_id)
        {:ok, type, payload} -> {:ok, typed_params(frame, metadata, type, payload)}
      end
    end
  end

  def message_params(%{"type" => "text"}, client_id) do
    {:error, "bad_request", "a text frame needs data.text", [client_id: client_id]}
  end

  # A rich message type (image, card, location, ...): stored as a typed
  # message (#68), validated by `Converger.Activities.Activity`.
  def message_params(%{"type" => type, "data" => data} = frame, client_id)
      when is_binary(type) and is_map(data) do
    with {:ok, metadata} <- metadata(frame, client_id),
         {:ok, ^type, payload} <- MessagePayload.from_frame(frame) do
      {:ok, typed_params(frame, metadata, type, payload)}
    end
  end

  def message_params(%{"type" => type}, client_id) do
    {:error, "bad_request", "a #{type} frame needs a data object", [client_id: client_id]}
  end

  defp plain_params(%{"data" => data} = frame, metadata, client_id) do
    case Map.get(data, "attachments") || [] do
      attachments when is_list(attachments) ->
        {:ok,
         %{
           "type" => "message",
           "text" => data["text"],
           "attachments" => attachments,
           "metadata" => metadata,
           "reply_to_id" => reply_to_id(frame)
         }}

      _ ->
        {:error, "bad_request", "data.attachments must be an array", [client_id: client_id]}
    end
  end

  defp typed_params(frame, metadata, type, payload) do
    %{
      "type" => "message",
      "message_type" => type,
      "payload" => payload,
      "metadata" => metadata,
      "reply_to_id" => reply_to_id(frame)
    }
  end

  defp metadata(frame, client_id) do
    case Map.get(frame, "metadata") || %{} do
      metadata when is_map(metadata) -> {:ok, metadata}
      _ -> {:error, "bad_request", "metadata must be an object", [client_id: client_id]}
    end
  end

  # `replyTo {id}` (section 5.3) names the activity this turn answers; it is
  # stored as the activity's `reply_to_id` (#28).
  defp reply_to_id(%{"replyTo" => %{"id" => id}}) when is_binary(id), do: id
  defp reply_to_id(_frame), do: nil
end
