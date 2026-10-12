defmodule ConvergerClient.ActivityPage do
  @moduledoc "A watermark page of `ConvergerClient.TenantAPI.list_activities/3`."
  use ConvergerClient.Model,
    fields: [
      data: {"data", ConvergerClient.Activity},
      watermark: "watermark",
      has_more: "has_more",
      limit: "limit"
    ]
end
