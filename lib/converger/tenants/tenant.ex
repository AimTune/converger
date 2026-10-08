defmodule Converger.Tenants.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field :name, :string
    field :api_key, :string
    field :status, :string, default: "active"
    field :alert_webhook_url, :string
    # Rate-limit overrides, see Converger.RateLimit and limits_changeset/2.
    field :limits, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(
          {map(),
           %{
             optional(atom()) =>
               atom()
               | {:array | :assoc | :embed | :in | :map | :parameterized | :supertype | :try,
                  any()}
           }}
          | %{
              :__struct__ => atom() | %{:__changeset__ => any(), optional(any()) => any()},
              optional(atom()) => any()
            },
          :invalid | %{optional(:__struct__) => none(), optional(atom() | binary()) => any()}
        ) :: Ecto.Changeset.t()
  @doc false
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :status, :alert_webhook_url])
    |> validate_required([:name])
    |> ensure_api_key()
    |> validate_required([:api_key, :status])
    |> validate_url(:alert_webhook_url)
    |> unique_constraint(:api_key)
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
    if get_field(changeset, :api_key) do
      changeset
    else
      put_change(changeset, :api_key, generate_api_key())
    end
  end

  defp generate_api_key do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end
end
