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
