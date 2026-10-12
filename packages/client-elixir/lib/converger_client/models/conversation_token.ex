defmodule ConvergerClient.ConversationToken do
  @moduledoc "A conversation-bound token (`ConvergerClient.ClientAPI.create_conversation/2`, `get_conversation/4`)."
  use ConvergerClient.Model,
    fields: [
      conversation_id: "conversationId",
      token: "token",
      expires_in: "expires_in",
      stream_url: "streamUrl"
    ]
end
