defmodule ConvergerClient.ConversationStatus do
  @moduledoc "Returned by the client API close and reopen calls."
  use ConvergerClient.Model,
    fields: [
      conversation_id: "conversationId",
      status: "status"
    ]
end
