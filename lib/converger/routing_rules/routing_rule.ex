defmodule Converger.RoutingRules.RoutingRule do
  use Ecto.Schema
  import Ecto.Changeset

  alias Converger.RoutingRules.Conditions

  @type t :: %__MODULE__{}

  @default_priority 100
  @priority_range -1_000_000..1_000_000//1

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routing_rules" do
    field :name, :string
    field :target_channel_ids, {:array, :binary_id}, default: []
    field :enabled, :boolean, default: true
    # Predicates over the activity (Converger.RoutingRules.Conditions);
    # `%{}` matches every activity.
    field :conditions, :map, default: %{}
    # Middleware chain (Converger.Pipeline.Middleware format) run for this
    # rule's targets after the target channel's own transformations.
    field :transformations, {:array, :map}, default: []
    # Rules of a source channel are evaluated in ascending priority; a
    # matching rule with stop_processing ends the evaluation.
    field :priority, :integer, default: @default_priority
    field :stop_processing, :boolean, default: false

    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :source_channel, Converger.Channels.Channel

    timestamps(type: :utc_datetime)
  end

  @fields [
    :name,
    :source_channel_id,
    :target_channel_ids,
    :enabled,
    :conditions,
    :transformations,
    :priority,
    :stop_processing
  ]

  @doc "Priority of a rule created without one."
  def default_priority, do: @default_priority

  # tenant_id is set once, on create (by the caller, from the authenticated
  # tenant); an update can never move a rule to another tenant.
  defp castable_fields(%__MODULE__{tenant_id: nil}), do: [:tenant_id | @fields]
  defp castable_fields(%__MODULE__{}), do: @fields

  @doc false
  def changeset(routing_rule, attrs) do
    routing_rule
    |> cast(normalize_conditions(attrs), castable_fields(routing_rule))
    |> validate_required([:name, :source_channel_id, :target_channel_ids, :tenant_id])
    |> validate_length(:target_channel_ids, min: 1, max: 20)
    |> validate_number(:priority,
      greater_than_or_equal_to: @priority_range.first,
      less_than_or_equal_to: @priority_range.last
    )
    |> validate_conditions()
    |> validate_transformations()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:source_channel_id)
    |> unique_constraint([:tenant_id, :name])
    |> validate_no_self_reference()
  end

  # A list of predicates is accepted as shorthand for {"all": [...]}; the
  # stored form is always an object.
  defp normalize_conditions(attrs) when is_map(attrs) do
    Enum.reduce([:conditions, "conditions"], attrs, fn key, acc ->
      case acc do
        %{^key => value} when is_list(value) or is_nil(value) ->
          Map.put(acc, key, Conditions.normalize(value))

        _ ->
          acc
      end
    end)
  end

  defp normalize_conditions(attrs), do: attrs

  defp validate_conditions(changeset) do
    validate_change(changeset, :conditions, fn :conditions, conditions ->
      case Conditions.validate(Conditions.normalize(conditions)) do
        :ok -> []
        {:error, message} -> [conditions: message]
      end
    end)
    |> update_change(:conditions, &Conditions.normalize/1)
  end

  defp validate_transformations(changeset) do
    validate_change(changeset, :transformations, fn :transformations, chain ->
      case Converger.Pipeline.Middleware.validate_chain(chain) do
        :ok -> []
        {:error, message} -> [transformations: message]
      end
    end)
  end

  defp validate_no_self_reference(changeset) do
    source = get_field(changeset, :source_channel_id)
    targets = get_field(changeset, :target_channel_ids) || []

    if source && source in targets do
      add_error(changeset, :target_channel_ids, "cannot include the source channel")
    else
      changeset
    end
  end
end
