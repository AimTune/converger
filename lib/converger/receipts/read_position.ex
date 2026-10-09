defmodule Converger.Receipts.ReadPosition do
  @moduledoc """
  The read watermark of one reader in one conversation: every activity with
  `seq <= read_seq` has been read. `reader_id` is the participant id of the
  WebSocket connection that sent the `read` frame (see
  `ConvergerWeb.ConvergerChannel`).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "conversation_reads" do
    field :reader_id, :string
    field :read_seq, :integer
    field :read_at, :utc_datetime_usec

    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :conversation, Converger.Conversations.Conversation

    timestamps(type: :utc_datetime_usec)
  end
end
