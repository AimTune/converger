defmodule ConvergerClient.ClientActivity do
  @moduledoc "An activity as the client API renders it (camelCase on the wire). Timestamps are ISO 8601 strings."
  use ConvergerClient.Model,
    fields: [
      id: "id",
      type: "type",
      from: {"from", ConvergerClient.ChannelAccount},
      text: "text",
      timestamp: "timestamp",
      attachments: "attachments",
      conversation_id: "conversationId",
      channel_data: "channelData",
      reply_to_id: "replyToId",
      edited_at: "editedAt",
      deleted_at: "deletedAt"
    ]
end
