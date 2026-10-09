defmodule Converger.Activities.Activity do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @types ~w(message event typing conversationUpdate endOfConversation)

  # Fields a client (REST body, WebSocket payload, inbound webhook) may set.
  @client_fields [:type, :text, :attachments, :metadata]

  # Fields only the server sets. `inserted_at` is deliberately absent:
  # the server timestamp always wins.
  @system_fields [:tenant_id, :conversation_id, :sender, :idempotency_key]

  @default_limits [
    max_text_bytes: 65_536,
    max_attachments: 10,
    max_attachment_bytes: 4_096,
    max_metadata_bytes: 16_384
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "activities" do
    field :type, :string, default: "message"
    field :sender, :string
    field :text, :string
    field :attachments, {:array, :map}, default: []
    field :metadata, :map, default: %{}
    field :idempotency_key, :string
    # Per-conversation sequence number, assigned by the server on insert.
    field :seq, :integer

    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :conversation, Converger.Conversations.Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Known activity types."
  def types, do: @types

  @doc "Client-settable fields."
  def client_fields, do: @client_fields

  @doc """
  Size limits, configurable via `config :converger, :activity_limits, [...]`.
  Sizes are in bytes; attachment and metadata sizes are measured as JSON.
  """
  def limits do
    Keyword.merge(@default_limits, Application.get_env(:converger, :activity_limits, []))
  end

  @doc """
  Full changeset for trusted internal callers: client fields plus system fields.
  """
  def changeset(activity, attrs) do
    activity
    |> client_changeset(attrs)
    |> system_changeset(attrs)
  end

  @doc """
  Casts and validates only the fields a client may set (`client_fields/0`).
  Anything else in `attrs` is ignored.
  """
  def client_changeset(activity, attrs) do
    limits = limits()

    activity
    |> cast(attrs, @client_fields)
    |> validate_inclusion(:type, @types)
    |> validate_length(:text, max: limits[:max_text_bytes], count: :bytes)
    |> validate_length(:attachments, max: limits[:max_attachments])
    |> validate_change(:attachments, &validate_attachments(&1, &2, limits[:max_attachment_bytes]))
    |> validate_json_size(:metadata, limits[:max_metadata_bytes])
  end

  @doc """
  Casts the server-controlled fields (tenant, conversation, sender, idempotency key).
  Never feed raw client input into this changeset.
  """
  def system_changeset(changeset_or_activity, attrs) do
    changeset_or_activity
    |> cast(attrs, @system_fields)
    |> validate_required([:sender, :tenant_id, :conversation_id])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:conversation_id)
    # Unique per monthly partition (`activities_pYYYY_MM_conversation_id_idempotency_key_index`,
    # ADR-0026); create_activity/2 also re-checks under the conversation lock,
    # which makes the key unique across partitions.
    |> unique_constraint([:conversation_id, :idempotency_key],
      name: "_conversation_id_idempotency_key_index",
      match: :suffix
    )
  end

  defp validate_attachments(field, attachments, max_bytes) do
    attachments
    |> Enum.with_index()
    |> Enum.flat_map(fn {attachment, index} ->
      size = json_size(attachment)

      if size > max_bytes,
        do: [{field, "attachment #{index} is #{size} bytes, max is #{max_bytes}"}],
        else: []
    end)
  end

  defp validate_json_size(changeset, field, max_bytes) do
    validate_change(changeset, field, fn ^field, value ->
      size = json_size(value)
      if size > max_bytes, do: [{field, "is #{size} bytes, max is #{max_bytes}"}], else: []
    end)
  end

  defp json_size(value), do: value |> Jason.encode!() |> byte_size()
end
