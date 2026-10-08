defmodule Converger.Tenants.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  alias Converger.Secrets

  @api_key_prefix "cvg_live_"
  # Number of random characters (after the prefix) kept for display.
  @display_chars 4

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

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Public prefix of every generated API key."
  def api_key_prefix, do: @api_key_prefix

  @doc false
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :status, :alert_webhook_url])
    |> validate_required([:name])
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
          []

        _ ->
          [{field, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end
end
