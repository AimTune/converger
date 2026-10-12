defmodule ConvergerClient.Ack do
  @moduledoc "The server ack of a socket send with a `clientId`."
  use ConvergerClient.Model,
    fields: [
      client_id: "clientId",
      id: "id",
      seq: "seq",
      timestamp: "timestamp",
      duplicate: "duplicate"
    ]
end
