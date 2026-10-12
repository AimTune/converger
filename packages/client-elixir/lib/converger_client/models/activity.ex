defmodule ConvergerClient.Activity do
  @moduledoc "The canonical activity (tenant API, delivery payloads and outbound webhook bodies, which add `timestamp`). Timestamps are ISO 8601 strings."
  use ConvergerClient.Model,
    fields: [
      id: "id",
      type: "type",
      sender: "sender",
      text: "text",
      attachments: "attachments",
      metadata: "metadata",
      idempotency_key: "idempotency_key",
      seq: "seq",
      reply_to_id: "reply_to_id",
      edited_at: "edited_at",
      deleted_at: "deleted_at",
      conversation_id: "conversation_id",
      tenant_id: "tenant_id",
      inserted_at: "inserted_at",
      timestamp: "timestamp"
    ]
end
