defmodule ConvergerClient.ChannelAccount do
  @moduledoc "The sender of a client API activity."
  use ConvergerClient.Model,
    fields: [
      id: "id",
      name: "name"
    ]
end
