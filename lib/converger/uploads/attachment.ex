defmodule Converger.Uploads.Attachment do
  @moduledoc """
  A stored file. The bytes live in the configured storage backend under
  `storage_key`; this row is the source of truth for ownership (tenant,
  conversation, activity) and integrity (size, sha256, sniffed content type).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "attachments" do
    field :storage_key, :string
    field :content_type, :string
    field :size, :integer
    field :sha256, :string
    field :filename, :string

    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :conversation, Converger.Conversations.Conversation
    belongs_to :activity, Converger.Activities.Activity

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for a new attachment. `id`, `tenant_id` and `conversation_id`
  are set programmatically on the struct, never cast.
  """
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:storage_key, :content_type, :size, :sha256, :filename])
    |> validate_required([:id, :tenant_id, :storage_key, :content_type, :size, :sha256])
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> validate_length(:filename, max: 255)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint(:storage_key)
  end
end
