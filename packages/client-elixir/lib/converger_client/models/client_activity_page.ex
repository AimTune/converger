defmodule ConvergerClient.ClientActivityPage do
  @moduledoc """
  A page of `ConvergerClient.ClientAPI.list_activities/4`.

  `watermark` is the integer seq of the last activity (an opaque string from
  servers before v3.0); pass it back unchanged as `:watermark`.
  """
  use ConvergerClient.Model,
    fields: [
      activities: {"activities", ConvergerClient.ClientActivity},
      watermark: "watermark",
      has_more: "has_more"
    ]
end
