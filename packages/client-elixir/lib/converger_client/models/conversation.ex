defmodule ConvergerClient.Conversation do
  @moduledoc "A conversation as the tenant API renders it. Timestamps are ISO 8601 strings."
  use ConvergerClient.Model,
    fields: [
      id: "id",
      status: "status",
      metadata: "metadata",
      channel_id: "channel_id",
      origin_channel_id: "origin_channel_id",
      tenant_id: "tenant_id",
      participant_id: "participant_id",
      participant: {"participant", ConvergerClient.Participant},
      channels: "channels",
      inserted_at: "inserted_at",
      updated_at: "updated_at"
    ]
end
