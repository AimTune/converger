defmodule Converger.Conversations.ConversationChannel do
  @moduledoc """
  A channel a conversation spans (ADR-0046).

  Roles:

    * `"origin"` - the channel the conversation started on, with the
      conversation's participant (written when the conversation is created);
    * `"target"` - a channel the pipeline delivered an activity of the
      conversation to (a routing rule target, or the origin of a reply);
    * `"member"` - a channel an activity of the conversation was written from
      that is neither (for example an agent console replying).

  A channel has one row per conversation, with the role it got first.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @roles ~w(origin target member)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "conversation_channels" do
    field :role, :string

    belongs_to :conversation, Converger.Conversations.Conversation
    belongs_to :channel, Converger.Channels.Channel
    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :participant, Converger.Participants.Participant

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Known roles."
  def roles, do: @roles
end
