defmodule ConvergerClient.ClientActivityPage do
  @moduledoc "A page of `ConvergerClient.ClientAPI.list_activities/4`."
  use ConvergerClient.Model,
    fields: [
      activities: {"activities", ConvergerClient.ClientActivity},
      watermark: "watermark",
      has_more: "has_more"
    ]
end
