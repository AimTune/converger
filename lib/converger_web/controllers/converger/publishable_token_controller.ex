defmodule ConvergerWeb.ConvergerAPI.PublishableTokenController do
  @moduledoc """
  `POST /api/v1/converger/tokens/publishable` (issue #195, ADR-0074): a
  browser exchanges the channel's publishable key for a token, with no
  backend of its own.

  Unlike `tokens/generate` with the channel secret, the caller chooses
  nothing: the end user is anonymous (`anon_...`, minted here) and the token
  is bound to one conversation, created here, so a visitor never reaches
  another visitor's conversation. The response's signed `resume` credential
  (`Converger.Auth.PublishableResume`) continues that conversation as the
  same end user on the next call (a page reload).

  Checks, in order: the per-IP limit (before any database work), the key,
  the `Origin` header against the channel's allowed origins, then the
  per-channel limit.
  """

  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Auth.{ConvergerToken, PublishableResume}
  alias Converger.{Channels, Conversations}
  alias Converger.Channels.Origins
  alias ConvergerWeb.APIError

  plug ConvergerWeb.Plugs.RateLimit, bucket: :publishable_token_ip, scope: :ip
  plug :authenticate_key
  plug :check_origin
  plug ConvergerWeb.Plugs.RateLimit, bucket: :publishable_token, scope: :channel

  action_fallback ConvergerWeb.FallbackController

  tags(["Client: Tokens"])

  operation(:create,
    summary: "Get a token with a publishable key",
    description:
      "For browsers without a backend: exchanges the channel's publishable key (`cvg_pk_...`) for a token bound to a new conversation of an anonymous end user, or, with `resume`, to the conversation of an earlier call. The request must come from one of the key's allowed origins (`Origin` header). An invalid or expired `resume` starts a new conversation (`resumed: false`).",
    operation_id: "createPublishableToken",
    security: [%{"publishableKey" => []}],
    request_body: json_schema("Options", ref("PublishableTokenRequest")),
    responses:
      with_errors(
        %{200 => json_schema("The token", ref("PublishableToken"))},
        [400, 401, 403, 429]
      )
  )

  def create(conn, params) do
    channel = conn.assigns.channel

    with {:ok, conversation, user_id, resumed?} <- conversation_for(channel, params["resume"]) do
      {:ok, token, claims} =
        ConvergerToken.generate_conversation_token(channel, conversation.id,
          user_id: user_id,
          source: "publishable"
        )

      conn
      |> put_status(:ok)
      |> json(%{
        conversationId: conversation.id,
        token: token,
        expires_in: max(claims["exp"] - Joken.current_time(), 0),
        userId: user_id,
        resume: PublishableResume.sign(channel.id, conversation.id, user_id),
        resumed: resumed?
      })
    end
  end

  # The resumed conversation when the credential is valid and the
  # conversation is still open in this channel; a new one otherwise.
  defp conversation_for(channel, resume) do
    with {:ok, %{conversation_id: id, user_id: user_id}} <-
           PublishableResume.verify(resume, channel.id),
         %Conversations.Conversation{channel_id: channel_id, status: "active"} = conversation
         when channel_id == channel.id <-
           Conversations.get_conversation(id, channel.tenant_id) do
      {:ok, conversation, user_id, true}
    else
      _ -> new_conversation(channel)
    end
  end

  defp new_conversation(channel) do
    case Conversations.create_conversation(%{
           "tenant_id" => channel.tenant_id,
           "channel_id" => channel.id,
           "metadata" => %{"source" => "publishable_key"}
         }) do
      {:ok, conversation} -> {:ok, conversation, anonymous_user_id(), false}
      {:error, _} = error -> error
    end
  end

  defp anonymous_user_id do
    "anon_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp authenticate_key(conn, _opts) do
    with ["Bearer " <> key | _] <- get_req_header(conn, "authorization"),
         %Channels.Channel{} = channel <-
           Channels.get_channel_by_publishable_key(String.trim(key)) do
      assign(conn, :channel, channel)
    else
      _ -> APIError.send_error(conn, "unauthorized", "Unknown or disabled publishable key")
    end
  end

  # Browsers always send Origin on a cross-origin POST (and on same-origin
  # POSTs); a request without one is not from a page the key allows.
  defp check_origin(conn, _opts) do
    case get_req_header(conn, "origin") do
      [origin | _] ->
        if Origins.allowed?(origin, conn.assigns.channel.allowed_origins),
          do: conn,
          else: origin_not_allowed(conn)

      [] ->
        origin_not_allowed(conn)
    end
  end

  defp origin_not_allowed(conn) do
    APIError.send_error(
      conn,
      "origin_not_allowed",
      "This origin may not use the publishable key; add it to the channel's allowed origins"
    )
  end
end
