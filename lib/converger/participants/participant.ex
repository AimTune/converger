defmodule Converger.Participants.Participant do
  @moduledoc """
  An external party on a channel - a WhatsApp phone number, a chat id, an
  email address - identified by `external_id`, unique per channel.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "participants" do
    field :external_id, :string
    field :display_name, :string
    field :metadata, :map, default: %{}

    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :channel, Converger.Channels.Channel

    has_many :conversations, Converger.Conversations.Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  `tenant_id` and `channel_id` are set by the caller on the struct, never cast.
  """
  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [:external_id, :display_name, :metadata])
    |> validate_required([:external_id, :tenant_id, :channel_id])
    |> validate_length(:external_id, max: 255)
    |> validate_length(:display_name, max: 255)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:channel_id)
    |> unique_constraint([:channel_id, :external_id])
  end
end
