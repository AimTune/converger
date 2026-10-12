defmodule ConvergerClient.Participant do
  @moduledoc "The external party of a conversation (for example a WhatsApp number)."
  use ConvergerClient.Model,
    fields: [
      id: "id",
      external_id: "external_id",
      display_name: "display_name",
      opted_out_at: "opted_out_at"
    ]
end
