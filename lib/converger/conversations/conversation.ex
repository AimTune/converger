defmodule Converger.Conversations.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "conversations" do
    field :status, :string, default: "active"
    # Highest activity `seq` handed out in this conversation (server-managed).
    field :last_seq, :integer, default: 0
    field :metadata, :map, default: %{}
    # The channel the conversation started on (set on insert from `channel_id`,
    # never cast). Replies written from other channels go back to it by
    # default (reply-back routing, ADR-0046). Nil only for rows the
    # migration has not backfilled yet: see `origin_channel_id/1`.
    field :origin_channel_id, :binary_id

    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :channel, Converger.Channels.Channel
    # External party of the conversation (e.g. a WhatsApp number), set by
    # inbound participant resolution; never cast. See Converger.Participants.
    belongs_to :participant, Converger.Participants.Participant

    has_many :activities, Converger.Activities.Activity
    # The channels the conversation spans (origin, routed targets, writers).
    has_many :conversation_channels, Converger.Conversations.ConversationChannel

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:status, :metadata, :tenant_id, :channel_id])
    |> validate_required([:status, :tenant_id, :channel_id])
    |> validate_inclusion(:status, ~w(active closed))
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:channel_id)
    |> put_origin()
  end

  # The origin is fixed when the conversation is created.
  defp put_origin(%{data: %{__meta__: %{state: :built}, origin_channel_id: nil}} = changeset),
    do: put_change(changeset, :origin_channel_id, get_field(changeset, :channel_id))

  defp put_origin(changeset), do: changeset

  @doc "The channel the conversation started on (its `channel_id` for rows not backfilled)."
  def origin_channel_id(%{origin_channel_id: id}) when is_binary(id), do: id
  def origin_channel_id(%{channel_id: id}), do: id
end
