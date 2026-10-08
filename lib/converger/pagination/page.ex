defmodule Converger.Pagination.Page do
  @moduledoc """
  One page of a keyset-paginated list (see `Converger.Pagination.keyset/2`).

    * `entries` - the rows of this page
    * `next_cursor` - opaque cursor for the next page, `nil` on the last page
    * `has_more` - whether more rows exist after this page
    * `limit` - the effective (clamped) page size
  """

  defstruct entries: [], next_cursor: nil, has_more: false, limit: nil

  @type t :: %__MODULE__{
          entries: list(),
          next_cursor: String.t() | nil,
          has_more: boolean(),
          limit: pos_integer() | nil
        }
end
