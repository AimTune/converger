defmodule ConvergerClient.ClientAPI do
  @moduledoc """
  The client API under `/api/v1/converger`, authenticated with converger
  tokens (`Authorization: Bearer`). Your backend mints tokens with the
  channel secret (`generate_token/2`) and hands conversation-bound tokens to
  end users, or uses them itself (for example with `ConvergerClient.Socket`).
  """

  import ConvergerClient, only: [request: 4, compact: 1, params: 1, seg: 1]

  alias ConvergerClient.{
    ClientActivityPage,
    ConversationStatus,
    ConversationToken,
    Error,
    ResourceResponse,
    TokenResponse
  }

  @type result(t) :: {:ok, t} | {:error, Error.t() | Exception.t()}

  @doc """
  Exchanges the channel secret for a converger token.

  Options: `:user_id`, `:scope` (only `"channel"`, for agent sockets).
  """
  @spec generate_token(ConvergerClient.t(), keyword()) :: result(TokenResponse.t())
  def generate_token(client, opts \\ []) do
    body =
      compact(%{
        "user" => if(opts[:user_id], do: %{"id" => opts[:user_id]}),
        "scope" => opts[:scope]
      })

    with {:ok, h} <- bearer(client.channel_secret, "channel_secret") do
      post(client, "/api/v1/converger/tokens/generate", h, body, &TokenResponse.from_map/1)
    end
  end

  @doc "Exchanges a valid token for a fresh one."
  @spec refresh_token(ConvergerClient.t(), String.t()) :: result(TokenResponse.t())
  def refresh_token(client, token) do
    with {:ok, h} <- bearer(token, "token"),
         do: post(client, "/api/v1/converger/tokens/refresh", h, nil, &TokenResponse.from_map/1)
  end

  @doc "Starts a conversation; the returned token is bound to it."
  @spec create_conversation(ConvergerClient.t(), String.t()) :: result(ConversationToken.t())
  def create_conversation(client, token) do
    with {:ok, h} <- bearer(token, "token"),
         do:
           post(client, "/api/v1/converger/conversations", h, nil, &ConversationToken.from_map/1)
  end

  @doc "A new conversation-bound token for an existing conversation. Options: `:watermark`."
  @spec get_conversation(ConvergerClient.t(), String.t(), String.t(), keyword()) ::
          result(ConversationToken.t())
  def get_conversation(client, token, conversation_id, opts \\ []) do
    with {:ok, h} <- bearer(token, "token"),
         {:ok, body} <-
           request(client, :get, "/api/v1/converger/conversations/#{seg(conversation_id)}",
             headers: h,
             params: params(watermark: opts[:watermark])
           ),
         do: {:ok, ConversationToken.from_map(body)}
  end

  @doc "Closes a conversation."
  @spec close_conversation(ConvergerClient.t(), String.t(), String.t()) ::
          result(ConversationStatus.t())
  def close_conversation(client, token, conversation_id),
    do: transition(client, token, conversation_id, "close")

  @doc "Reopens a conversation."
  @spec reopen_conversation(ConvergerClient.t(), String.t(), String.t()) ::
          result(ConversationStatus.t())
  def reopen_conversation(client, token, conversation_id),
    do: transition(client, token, conversation_id, "reopen")

  @doc """
  Posts an activity as the end user.

  `attrs` (map or keyword): `:type`, `:text`, `:from_id`, `:attachments`,
  `:reply_to_id`, `:channel_data`. Options: `:idempotency_key`.
  """
  @spec post_activity(ConvergerClient.t(), String.t(), String.t(), map() | keyword(), keyword()) ::
          result(ResourceResponse.t())
  def post_activity(client, token, conversation_id, attrs, opts \\ []) do
    a = Map.new(attrs)

    body =
      compact(%{
        "type" => a[:type],
        "text" => a[:text],
        "from" => if(a[:from_id], do: %{"id" => a[:from_id]}),
        "attachments" => a[:attachments],
        "replyToId" => a[:reply_to_id],
        "channelData" => a[:channel_data]
      })

    with {:ok, h} <- bearer(token, "token") do
      post(
        client,
        "/api/v1/converger/conversations/#{seg(conversation_id)}/activities",
        h ++ idempotency(opts),
        body,
        &ResourceResponse.from_map/1
      )
    end
  end

  @doc """
  Activities after a watermark, oldest first. Options: `:watermark` (the
  integer seq or a legacy opaque string, sent as is), `:limit`.
  """
  @spec list_activities(ConvergerClient.t(), String.t(), String.t(), keyword()) ::
          result(ClientActivityPage.t())
  def list_activities(client, token, conversation_id, opts \\ []) do
    with {:ok, h} <- bearer(token, "token"),
         {:ok, body} <-
           request(
             client,
             :get,
             "/api/v1/converger/conversations/#{seg(conversation_id)}/activities",
             headers: h,
             params: params(watermark: opts[:watermark], limit: opts[:limit])
           ),
         do: {:ok, ClientActivityPage.from_map(body)}
  end

  defp transition(client, token, conversation_id, action) do
    with {:ok, h} <- bearer(token, "token") do
      post(
        client,
        "/api/v1/converger/conversations/#{seg(conversation_id)}/#{action}",
        h,
        nil,
        &ConversationStatus.from_map/1
      )
    end
  end

  defp post(client, path, headers, body, build) do
    opts = if body, do: [headers: headers, json: body], else: [headers: headers]

    with {:ok, decoded} <- request(client, :post, path, opts), do: {:ok, build.(decoded)}
  end

  defp bearer(value, _what) when is_binary(value) and value != "",
    do: {:ok, [{"authorization", "Bearer " <> value}]}

  defp bearer(_, what), do: {:error, ArgumentError.exception("#{what} is required")}

  defp idempotency(opts) do
    case opts[:idempotency_key] do
      nil -> []
      key -> [{"x-idempotency-key", key}]
    end
  end
end
