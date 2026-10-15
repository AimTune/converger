defmodule Converger.Channels.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  alias Converger.Channels.Adapter

  @type t :: %__MODULE__{}

  @channel_modes ~w(inbound outbound duplex)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "channels" do
    field :name, :string
    field :type, :string, default: "webhook"
    field :mode, :string, default: "duplex"
    field :secret, Converger.Encrypted.Binary, redact: true
    field :secret_hash, :binary, redact: true
    field :require_signature, :boolean, default: true
    field :status, :string, default: "active"

    field :config, Converger.Encrypted.Map,
      default: %{},
      redact: true,
      skip_default_validation: true

    field :transformations, {:array, :map}, default: []
    # Per-channel delivery retry overrides, see Converger.Pipeline.RetryPolicy.
    field :retry_policy, :map, default: %{}
    # Outbound rate limit ("80/s", "1000/m", "5000/h"), see Converger.Channels.Circuit.
    field :rate_limit, :string
    # Delivery circuit breaker, managed by Converger.Channels.Circuit (never cast).
    field :circuit_state, :string, default: "closed"
    field :circuit_changed_at, :utc_datetime_usec
    field :consecutive_failures, :integer, default: 0
    # Browser-safe client credential and the origins allowed to use it
    # (issue #195, ADR-0074), managed by Converger.Channels (never cast by
    # changeset/2).
    field :publishable_key, :string
    field :allowed_origins, {:array, :string}, default: []
    belongs_to :tenant, Converger.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The registered channel types, see `Converger.Channels.Adapter.types/0`."
  def channel_types, do: Adapter.types()
  def channel_modes, do: @channel_modes

  @doc false
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :name,
      :status,
      :tenant_id,
      :type,
      :mode,
      :secret,
      :require_signature,
      :config,
      :transformations,
      :retry_policy,
      :rate_limit
    ])
    |> validate_required([:name, :status, :tenant_id])
    |> validate_inclusion(:type, Adapter.types())
    |> validate_inclusion(:mode, @channel_modes)
    |> validate_channel_config()
    |> validate_unsupported_activities()
    |> validate_show_tool_traces()
    |> validate_mode_compatibility()
    |> validate_transformations()
    |> validate_retry_policy()
    |> validate_rate_limit()
    |> unique_constraint([:tenant_id, :name])
    |> ensure_secret()
    |> put_secret_hash()
    |> unique_constraint(:secret_hash)
  end

  # The adapter's config schema and checks. Fields required only on signed
  # channels (`required: :with_signature`, e.g. Meta's app_secret) depend on
  # `require_signature`; fields required per direction (`required: :inbound`,
  # e.g. a broker channel's topic_in) depend on `mode`.
  defp validate_channel_config(changeset) do
    type = get_field(changeset, :type)
    config = get_field(changeset, :config) || %{}

    opts = [
      require_signature: get_field(changeset, :require_signature) == true,
      mode: get_field(changeset, :mode) || "duplex"
    ]

    case Adapter.validate_config(type, config, opts) do
      :ok -> changeset
      {:error, message} -> add_error(changeset, :config, message)
    end
  end

  # Optional config key: what to do with activity types the adapter cannot
  # deliver natively (Converger.Activities.Downgrade).
  defp validate_unsupported_activities(changeset) do
    config = get_field(changeset, :config) || %{}
    policies = Converger.Activities.Downgrade.policies()

    policy = Map.get(config, "unsupported_activities")

    if is_nil(policy) or policy in policies do
      changeset
    else
      add_error(
        changeset,
        :config,
        "unsupported_activities must be one of: #{Enum.join(policies, ", ")}"
      )
    end
  end

  # Optional config key: deliver `tool_call` traces to this channel as a
  # `name: status` line (Converger.Activities.Downgrade, #68).
  defp validate_show_tool_traces(changeset) do
    config = get_field(changeset, :config) || %{}

    if Map.get(config, "show_tool_traces") in [nil, true, false],
      do: changeset,
      else: add_error(changeset, :config, "show_tool_traces must be a boolean")
  end

  defp validate_mode_compatibility(changeset) do
    type = get_field(changeset, :type)
    mode = get_field(changeset, :mode) || "duplex"

    supported = Converger.Channels.Adapter.supported_modes(type)

    if mode in supported do
      changeset
    else
      add_error(
        changeset,
        :mode,
        "#{type} channels only support modes: #{Enum.join(supported, ", ")}"
      )
    end
  end

  defp validate_retry_policy(changeset) do
    validate_change(changeset, :retry_policy, fn :retry_policy, policy ->
      case Converger.Pipeline.RetryPolicy.validate(policy) do
        :ok -> []
        {:error, message} -> [retry_policy: message]
      end
    end)
  end

  defp validate_rate_limit(changeset) do
    validate_change(changeset, :rate_limit, fn :rate_limit, value ->
      case Converger.Channels.Circuit.parse_rate_limit(value) do
        {:ok, _} -> []
        :error -> [rate_limit: "must look like 80/s, 1000/m or 5000/h"]
      end
    end)
  end

  defp validate_transformations(changeset) do
    transformations = get_field(changeset, :transformations) || []

    if transformations == [] do
      changeset
    else
      case Converger.Pipeline.Middleware.validate_chain(transformations) do
        :ok -> changeset
        {:error, message} -> add_error(changeset, :transformations, message)
      end
    end
  end

  @doc """
  A changeset replacing the channel's secret with a freshly generated one
  (and its lookup hash). The old secret stops matching immediately.
  """
  def rotate_secret_changeset(channel) do
    channel
    |> change()
    |> put_change(:secret, generate_secret())
    |> put_secret_hash()
    |> unique_constraint(:secret_hash)
  end

  defp ensure_secret(changeset) do
    if get_field(changeset, :secret) do
      changeset
    else
      put_change(changeset, :secret, generate_secret())
    end
  end

  # The secret is stored encrypted (non-deterministic), so lookups by secret
  # go through its SHA-256 digest instead.
  defp put_secret_hash(changeset) do
    case fetch_change(changeset, :secret) do
      {:ok, secret} when is_binary(secret) ->
        put_change(changeset, :secret_hash, Converger.Secrets.hash(secret))

      _ ->
        changeset
    end
  end

  @publishable_key_prefix "cvg_pk_"

  @doc "The prefix of every publishable key."
  def publishable_key_prefix, do: @publishable_key_prefix

  @doc """
  A changeset for the channel's publishable key settings (ADR-0074):
  `allowed_origins` (a list, or text with one origin per line, see
  `Converger.Channels.Origins`). `:publishable_key` is `:keep` (default),
  `:new` (generate or rotate) or `:none` (disable). A key needs at least one
  allowed origin.
  """
  def client_access_changeset(channel, attrs, key \\ :keep) do
    changeset =
      case Map.fetch(attrs, "allowed_origins") do
        {:ok, value} ->
          case Converger.Channels.Origins.cast_list(value) do
            {:ok, origins} -> change(channel, allowed_origins: origins)
            {:error, message} -> channel |> change() |> add_error(:allowed_origins, message)
          end

        :error ->
          change(channel)
      end

    changeset
    |> put_publishable_key(key)
    |> validate_key_has_origins()
    |> unique_constraint(:publishable_key, name: :channels_publishable_key_index)
  end

  defp put_publishable_key(changeset, :keep), do: changeset
  defp put_publishable_key(changeset, :none), do: put_change(changeset, :publishable_key, nil)

  defp put_publishable_key(changeset, :new),
    do: put_change(changeset, :publishable_key, generate_publishable_key())

  # Skipped when the origins themselves are invalid, so that error is shown.
  defp validate_key_has_origins(changeset) do
    if get_field(changeset, :publishable_key) && get_field(changeset, :allowed_origins) == [] &&
         not Keyword.has_key?(changeset.errors, :allowed_origins),
       do:
         add_error(
           changeset,
           :allowed_origins,
           "add at least one origin to use a publishable key"
         ),
       else: changeset
  end

  @doc "A new random publishable key (`cvg_pk_` and 32 random bytes, base64url)."
  def generate_publishable_key do
    @publishable_key_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  @doc "A new random channel secret."
  def generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end
end
