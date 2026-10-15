defmodule ConvergerClient.TenantAPI do
  @moduledoc """
  The tenant API under `/api/v1`, authenticated with the tenant API key
  (`x-api-key`). For bots, CRMs and other backends.
  """

  import ConvergerClient, only: [request: 4, compact: 1, params: 1, seg: 1]

  alias ConvergerClient.{Activity, ActivityPage, Conversation, Error, Page}

  @type result(t) :: {:ok, t} | {:error, Error.t() | Exception.t()}

  @doc """
  The tenant's conversations, newest first.

  Options: `:limit`, `:cursor`, `:status`, `:channel_id`, `:external_id`.
  """
  @spec list_conversations(ConvergerClient.t(), keyword()) :: result(Page.t())
  def list_conversations(client, opts \\ []) do
    p = params(Keyword.take(opts, [:limit, :cursor, :status, :channel_id, :external_id]))

    with {:ok, h} <- api_key(client),
         {:ok, body} <- request(client, :get, "/api/v1/conversations", headers: h, params: p),
         do: {:ok, Page.from_map(Map.merge(body["meta"] || %{}, %{"data" => body["data"]}))}
  end

  @doc "A conversation with its participant."
  @spec get_conversation(ConvergerClient.t(), String.t()) :: result(Conversation.t())
  def get_conversation(client, conversation_id),
    do: conversation(client, :get, "/api/v1/conversations/#{seg(conversation_id)}")

  @doc "Closes a conversation."
  @spec close_conversation(ConvergerClient.t(), String.t()) :: result(Conversation.t())
  def close_conversation(client, conversation_id),
    do: conversation(client, :post, "/api/v1/conversations/#{seg(conversation_id)}/close")

  @doc "Reopens a conversation."
  @spec reopen_conversation(ConvergerClient.t(), String.t()) :: result(Conversation.t())
  def reopen_conversation(client, conversation_id),
    do: conversation(client, :post, "/api/v1/conversations/#{seg(conversation_id)}/reopen")

  @doc """
  Posts an activity (for example a bot reply with `sender: "bot"`).

  `attrs` (map or keyword): `:type`, `:sender`, `:text`, `:attachments`,
  `:metadata`, `:reply_to_id`. Options: `:idempotency_key`.
  """
  @spec post_activity(ConvergerClient.t(), String.t(), map() | keyword(), keyword()) ::
          result(Activity.t())
  def post_activity(client, conversation_id, attrs, opts \\ []) do
    a = Map.new(attrs)

    body =
      compact(%{
        "type" => a[:type],
        "sender" => a[:sender],
        "text" => a[:text],
        "attachments" => a[:attachments],
        "metadata" => a[:metadata],
        "reply_to_id" => a[:reply_to_id]
      })

    idem =
      if opts[:idempotency_key], do: [{"x-idempotency-key", opts[:idempotency_key]}], else: []

    with {:ok, h} <- api_key(client),
         {:ok, body} <-
           request(client, :post, "/api/v1/conversations/#{seg(conversation_id)}/activities",
             headers: h ++ idem,
             json: body
           ),
         do: {:ok, Activity.from_map(body["data"])}
  end

  @doc """
  A conversation's activities after a watermark, oldest first. Options: `:watermark`
  (the integer seq or a legacy opaque string, sent as is), `:limit`.
  """
  @spec list_activities(ConvergerClient.t(), String.t(), keyword()) :: result(ActivityPage.t())
  def list_activities(client, conversation_id, opts \\ []) do
    p = params(watermark: opts[:watermark], limit: opts[:limit])

    with {:ok, h} <- api_key(client),
         {:ok, body} <-
           request(client, :get, "/api/v1/conversations/#{seg(conversation_id)}/activities",
             headers: h,
             params: p
           ),
         do:
           {:ok, ActivityPage.from_map(Map.merge(body["meta"] || %{}, %{"data" => body["data"]}))}
  end

  defp conversation(client, method, path) do
    with {:ok, h} <- api_key(client),
         {:ok, body} <- request(client, method, path, headers: h),
         do: {:ok, Conversation.from_map(body["data"])}
  end

  defp api_key(%{api_key: key}) when is_binary(key) and key != "",
    do: {:ok, [{"x-api-key", key}]}

  defp api_key(_), do: {:error, ArgumentError.exception("api_key is required for the tenant API")}
end
