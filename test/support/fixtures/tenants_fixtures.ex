defmodule Converger.TenantsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Converger.Tenants` context.
  """

  def unique_tenant_name, do: "Tenant #{System.unique_integer()}"

  def tenant_fixture(attrs \\ %{}) do
    {:ok, tenant} =
      attrs
      |> Enum.into(%{
        name: unique_tenant_name(),
        status: "active"
      })
      |> Converger.Tenants.create_tenant()

    tenant
  end
end
