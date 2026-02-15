defmodule Converger.Tenants do
  @moduledoc """
  The Tenants context.
  """

  import Ecto.Query, warn: false
  alias Converger.Repo
  alias Converger.Tenants.Tenant

  def list_tenants do
    Repo.all(Tenant)
  end

  def get_tenant!(id), do: Repo.get!(Tenant, id)

  def get_tenant_by_api_key(api_key) do
    Repo.get_by(Tenant, api_key: api_key)
  end

  def create_tenant(attrs \\ %{}) do
    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert()
  end

  def update_tenant(%Tenant{} = tenant, attrs) do
    tenant
    |> Tenant.changeset(attrs)
    |> Repo.update()
  end

  def delete_tenant(%Tenant{} = tenant) do
    Repo.delete(tenant)
  end

  def change_tenant(%Tenant{} = tenant, attrs \\ %{}) do
    Tenant.changeset(tenant, attrs)
  end
end
