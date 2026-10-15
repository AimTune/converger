defmodule Converger.Tenants.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  alias Converger.Secrets

  @api_key_prefix "cvg_live_"
  # Number of random characters (after the prefix) kept for display.
  @display_chars 4
  @tiers ~w(high default bulk)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field :name, :string
    # Plaintext API key. Only set right after creation or rotation so it can
    # be shown once; it is never persisted.
    field :api_key, :string, virtual: true, redact: true
    field :api_key_hash, :binary, redact: true
    field :api_key_prefix, :string
    field :previous_api_key_hash, :binary, redact: true
    field :previous_api_key_expires_at, :utc_datetime_usec
    field :status, :string, default: "active"
    field :alert_webhook_url, :string
    # Delivery queue tier, see Converger.Pipeline.Oban.queue_for_tier/1.
    field :tier, :string, default: "default"
    # Rate-limit overrides, see Converger.RateLimit and limits_changeset/2.
    field :limits, :map, default: %{}
    field :allowed_upload_types, {:array, :string}
    # Activities and deliveries older than this many days are archived to
    # object storage and removed (Converger.Retention, ADR-0034).
    field :retention_days, :integer, default: 365

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Public prefix of every generated API key."
  def api_key_prefix, do: @api_key_prefix

  @doc "Delivery queue tiers, see `Converger.Pipeline.Oban.queue_for_tier/1`."
  def tiers, do: @tiers

  @doc false
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [
      :name,
      :status,
      :alert_webhook_url,
      :allowed_upload_types,
      :tier,
      :retention_days
    ])
    |> validate_required([:name, :retention_days])
    |> validate_inclusion(:tier, @tiers)
    |> validate_number(:retention_days,
      greater_than_or_equal_to: Converger.Retention.min_retention_days()
    )
    |> ensure_api_key()
    |> validate_required([:api_key_hash, :status])
    |> validate_url(:alert_webhook_url)
    |> unique_constraint(:api_key_hash)
  end

  @doc """
  Replaces the API key with a freshly generated one. The current key stays
  valid until `previous_expires_at`.
  """
  def rotate_api_key_changeset(%__MODULE__{} = tenant, %DateTime{} = previous_expires_at) do
    tenant
    |> change(
      previous_api_key_hash: tenant.api_key_hash,
      previous_api_key_expires_at: previous_expires_at
    )
    |> put_new_api_key()
    |> unique_constraint(:api_key_hash)
  end

  @doc "Masked representation of the key for display (`cvg_live_abcd****`)."
  def masked_api_key(%__MODULE__{api_key_prefix: prefix}) when is_binary(prefix),
    do: prefix <> "****"

  def masked_api_key(_), do: "****"

  @doc "Generates a new random API key."
  def generate_api_key do
    @api_key_prefix <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
  end

  @doc """
  Changeset for the per-tenant rate-limit overrides.

  `limits` maps a bucket name (see `Converger.RateLimit.tenant_buckets/0`) to
  `%{"limit" => pos_integer, "scale_ms" => pos_integer}`.
  """
  def limits_changeset(tenant, limits) when is_map(limits) do
    normalized =
      Map.new(limits, fn {bucket, spec} ->
        spec = if is_map(spec), do: Map.new(spec, fn {k, v} -> {to_string(k), v} end), else: spec
        {to_string(bucket), spec}
      end)

    tenant
    |> change(limits: normalized)
    |> validate_change(:limits, fn :limits, value -> validate_limits(value) end)
  end

  defp validate_limits(limits) do
    buckets = Converger.RateLimit.tenant_buckets()

    Enum.flat_map(limits, fn {bucket, spec} ->
      cond do
        bucket not in buckets ->
          [limits: "unknown rate limit bucket #{inspect(bucket)}"]

        not match?(
          %{"limit" => l, "scale_ms" => s}
          when is_integer(l) and l > 0 and is_integer(s) and s > 0,
          spec
        ) ->
          [limits: "#{bucket} must have a positive integer limit and scale_ms"]

        map_size(spec) != 2 ->
          [limits: "#{bucket} only accepts limit and scale_ms"]

        true ->
          []
      end
    end)
  end

  defp ensure_api_key(changeset) do
    if get_field(changeset, :api_key_hash) do
      changeset
    else
      put_new_api_key(changeset)
    end
  end

  defp put_new_api_key(changeset) do
    api_key = generate_api_key()

    changeset
    |> put_change(:api_key, api_key)
    |> put_change(:api_key_hash, Secrets.hash(api_key))
    |> put_change(
      :api_key_prefix,
      String.slice(api_key, 0, String.length(@api_key_prefix) + @display_chars)
    )
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          # The server POSTs health alerts here: apply the same SSRF guard
          # as webhook channels (private, loopback and metadata targets).
          case Converger.Channels.UrlGuard.check(value) do
            :ok -> []
            {:error, message} -> [{field, "is not allowed: #{message}"}]
          end

        _ ->
          [{field, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end
end
