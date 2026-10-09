defmodule Converger.Archive.Part do
  @moduledoc """
  One archived object: up to `part_rows` rows of one table, tenant and month,
  stored as JSONL.gz at `archive/<tenant_id>/<YYYY-MM>/<table>-<NNNNN>.jsonl.gz`
  (see `Converger.Archive`).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "archive_parts" do
    field :tenant_id, :binary_id
    field :table_name, :string
    field :month, :date
    field :part, :integer
    # "detached": exported from a detached month partition, which is then
    # dropped. "deleted": exported from a live partition and deleted row by
    # row (a tenant whose retention ended before the other tenants' in that
    # month).
    field :mode, :string
    field :object_key, :string
    field :row_count, :integer
    field :byte_size, :integer
    field :sha256, :string
    field :last_id, :binary_id
    field :verified_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
