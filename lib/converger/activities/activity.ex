defmodule Converger.Activities.Activity do
  use Ecto.Schema
  import Ecto.Changeset

  alias Converger.Activities.ActivityAttachment

  @type t :: %__MODULE__{}

  # Converger's activity vocabulary (docs/concepts/activities.md). Kept stable:
  # removing or renaming a type is a breaking protocol change.
  @types ~w(message event typing messageReaction messageUpdate messageDelete
            conversationUpdate endOfConversation deliveryReceipt)

  # Types only the server may create; clients get a 422 for them.
  @internal_types ~w(deliveryReceipt)

  # Types that act on another activity of the same conversation, named by
  # `reply_to_id` (required for them). For `message` the field is optional
  # and means a threaded reply.
  @reference_types ~w(messageReaction messageUpdate messageDelete)

  # A reaction's `text` is the emoji (or a short reaction name).
  @max_reaction_bytes 64

  # Fields a client (REST body, WebSocket payload, inbound webhook) may set.
  @client_fields [:type, :text, :attachments, :metadata, :reply_to_id]

  # Fields only the server sets. `inserted_at` is deliberately absent:
  # the server timestamp always wins. `edited_at` / `deleted_at` are never
  # cast: the server stamps them on the original activity.
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
    # Stamped by the server on the original when a messageUpdate /
    # messageDelete referencing it is accepted. The original's content is
    # left unchanged; clients apply the update or delete.
    field :edited_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :reply_to, __MODULE__, foreign_key: :reply_to_id
    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :conversation, Converger.Conversations.Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Known activity types, including internal ones."
  def types, do: @types

  @doc "Activity types a client may send (`types/0` without the internal ones)."
  def client_types, do: @types -- @internal_types

  @doc "Server-only activity types."
  def internal_types, do: @internal_types

  @doc "Types that require `reply_to_id` (they act on another activity)."
  def reference_types, do: @reference_types

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

  Options: `internal: true` also accepts the server-only types
  (`internal_types/0`).
  """
  def changeset(activity, attrs, opts \\ []) do
    activity
    |> client_changeset(attrs, opts)
    |> system_changeset(attrs)
  end

  @doc """
  Casts and validates only the fields a client may set (`client_fields/0`).
  Anything else in `attrs` is ignored.

  Attachments are validated and normalised with
  `Converger.Activities.ActivityAttachment`. Whether `reply_to_id` points at
  an activity of the same conversation is checked by
  `Converger.Activities.create_activity/2`, which needs the database.

  Options: `internal: true` also accepts the server-only types.
  """
  def client_changeset(activity, attrs, opts \\ []) do
    limits = limits()
    allowed_types = if Keyword.get(opts, :internal, false), do: @types, else: client_types()

    activity
    |> cast(attrs, @client_fields)
    |> validate_inclusion(:type, allowed_types)
    |> validate_length(:text, max: limits[:max_text_bytes], count: :bytes)
    |> validate_length(:attachments, max: limits[:max_attachments])
    |> normalize_attachments(limits[:max_attachment_bytes])
    |> validate_json_size(:metadata, limits[:max_metadata_bytes])
    |> validate_change(:reply_to_id, fn :reply_to_id, id ->
      # :binary_id casts any binary; an activity id is always a UUID.
      if match?({:ok, _}, Ecto.UUID.cast(id)), do: [], else: [reply_to_id: "is invalid"]
    end)
    |> validate_type_rules()
    |> foreign_key_constraint(:reply_to_id)
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
    # ADR-0034); create_activity/2 also re-checks under the conversation lock,
    # which makes the key unique across partitions.
    |> unique_constraint([:conversation_id, :idempotency_key],
      name: "_conversation_id_idempotency_key_index",
      match: :suffix
    )
  end

  # Each attachment must be a valid ActivityAttachment; valid ones are stored
  # in their normalised wire form. Errors name the attachment index. Only
  # runs on a change, so attachments stored before the schema existed are
  # never re-validated.
  defp normalize_attachments(changeset, max_bytes) do
    case fetch_change(changeset, :attachments) do
      {:ok, attachments} when is_list(attachments) ->
        {normalized, errors} =
          attachments
          |> Enum.with_index()
          |> Enum.map_reduce([], fn {attachment, index}, errors ->
            case ActivityAttachment.normalize(attachment) do
              {:ok, wire} -> {wire, errors ++ size_errors(wire, index, max_bytes)}
              {:error, cs} -> {attachment, errors ++ attachment_errors(cs, index)}
            end
          end)

        if errors == [],
          do: put_change(changeset, :attachments, normalized),
          else: Enum.reduce(errors, changeset, &add_error(&2, :attachments, &1))

      _ ->
        changeset
    end
  end

  defp size_errors(attachment, index, max_bytes) do
    size = json_size(attachment)

    if size > max_bytes,
      do: ["attachment #{index} is #{size} bytes, max is #{max_bytes}"],
      else: []
  end

  defp attachment_errors(changeset, index) do
    changeset
    |> traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"attachment #{index}: #{wire_name(field)} #{&1}")
    end)
  end

  defp wire_name(field) do
    [first | rest] = field |> Atom.to_string() |> String.split("_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  # Per-type rules that need no database access.
  defp validate_type_rules(changeset) do
    type = get_field(changeset, :type)

    changeset =
      if type in @reference_types,
        do: validate_required(changeset, [:reply_to_id], message: "is required for #{type}"),
        else: changeset

    validate_type_content(changeset, type)
  end

  defp validate_type_content(changeset, "messageReaction"),
    do: validate_length(changeset, :text, max: @max_reaction_bytes, count: :bytes)

  defp validate_type_content(changeset, "messageUpdate") do
    text = get_field(changeset, :text)
    attachments = get_field(changeset, :attachments) || []

    if (is_binary(text) and String.trim(text) != "") or attachments != [],
      do: changeset,
      else: add_error(changeset, :text, "is required for messageUpdate (or attachments)")
  end

  defp validate_type_content(changeset, _type), do: changeset

  defp validate_json_size(changeset, field, max_bytes) do
    validate_change(changeset, field, fn ^field, value ->
      size = json_size(value)
      if size > max_bytes, do: [{field, "is #{size} bytes, max is #{max_bytes}"}], else: []
    end)
  end

  defp json_size(value), do: value |> Jason.encode!() |> byte_size()
end
