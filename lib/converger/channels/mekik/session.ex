defmodule Converger.Channels.Mekik.Session do
  @moduledoc """
  The upstream mekik conversation of one (mekik channel, Converger
  conversation) pair, see `Converger.Channels.Mekik.Sessions`.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "mekik_sessions" do
    field :mekik_conversation_id, :string
    field :mekik_user_id, :string
    # Highest mekik persistent-frame seq handled (written lazily).
    field :watermark, :integer, default: 0

    belongs_to :channel, Converger.Channels.Channel
    belongs_to :conversation, Converger.Conversations.Conversation
    belongs_to :tenant, Converger.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end
end
