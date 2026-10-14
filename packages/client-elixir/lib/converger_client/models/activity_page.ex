defmodule ConvergerClient.ActivityPage do
  @moduledoc """
  A watermark page of `ConvergerClient.TenantAPI.list_activities/3`.

  `watermark` is the integer seq of the last activity (an opaque string from
  servers before v3.0); pass it back unchanged as `:watermark`.
  """
  use ConvergerClient.Model,
    fields: [
      data: {"data", ConvergerClient.Activity},
      watermark: "watermark",
      has_more: "has_more",
      limit: "limit"
    ]
end
