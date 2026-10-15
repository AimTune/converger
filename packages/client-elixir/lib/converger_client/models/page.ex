defmodule ConvergerClient.Page do
  @moduledoc "A keyset page of `ConvergerClient.TenantAPI.list_conversations/2` (`data` holds `ConvergerClient.Conversation` structs)."
  use ConvergerClient.Model,
    fields: [
      data: {"data", ConvergerClient.Conversation},
      next_cursor: "next_cursor",
      has_more: "has_more",
      limit: "limit"
    ]
end
