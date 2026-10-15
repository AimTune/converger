defmodule ConvergerClient.TokenResponse do
  @moduledoc "Returned by `ConvergerClient.ClientAPI.generate_token/2` and `refresh_token/2`."
  use ConvergerClient.Model,
    fields: [
      conversation_id: "conversationId",
      token: "token",
      expires_in: "expires_in"
    ]
end
