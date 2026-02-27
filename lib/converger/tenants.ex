defmodule Converger.Tenants do
  @moduledoc """
  The Tenants context.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Converger.Repo
  alias Converger.Tenants.Tenant
  alias Converger.AuditLogs
  alias Converger.AuditLogs.Changes

  def list_tenants do
    Repo.all(Tenant)
  end

  def get_tenant!(id), do: Repo.get!(Tenant, id)

  def get_tenant_by_api_key(api_key) do
    Repo.get_by(Tenant, api_key: api_key)
  end

  def create_tenant(attrs \\ %{}, actor \\ nil) do
    changeset = Tenant.changeset(%Tenant{}, attrs)

    if actor do
      Multi.new()
      |> Multi.insert(:tenant, changeset)
      |> Multi.insert(:audit_log, fn %{tenant: tenant} ->
        AuditLogs.build_audit_log_entry(%{
          actor_type: actor.type,
          actor_id: actor.id,
          action: "create",
          resource_type: "tenant",
          resource_id: tenant.id,
          changes: Changes.for_create(tenant)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{tenant: tenant}} -> {:ok, tenant}
        {:error, :tenant, changeset, _} -> {:error, changeset}
      end
    else
      Repo.insert(changeset)
    end
  end

  def update_tenant(%Tenant{} = tenant, attrs, actor \\ nil) do
    changeset = Tenant.changeset(tenant, attrs)

    if actor do
      Multi.new()
      |> Multi.update(:tenant, changeset)
      |> Multi.insert(:audit_log, fn %{tenant: updated} ->
        AuditLogs.build_audit_log_entry(%{
          actor_type: actor.type,
          actor_id: actor.id,
          action: "update",
          resource_type: "tenant",
          resource_id: tenant.id,
          changes: Changes.for_update(tenant, updated)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{tenant: updated}} -> {:ok, updated}
        {:error, :tenant, changeset, _} -> {:error, changeset}
      end
    else
      Repo.update(changeset)
    end
  end

  def delete_tenant(%Tenant{} = tenant, actor \\ nil) do
    if actor do
      Multi.new()
      |> Multi.insert(:audit_log, fn _ ->
        AuditLogs.build_audit_log_entry(%{
          actor_type: actor.type,
          actor_id: actor.id,
          action: "delete",
          resource_type: "tenant",
          resource_id: tenant.id,
          changes: Changes.for_delete(tenant)
        })
      end)
      |> Multi.delete(:tenant, tenant)
      |> Repo.transaction()
      |> case do
        {:ok, %{tenant: tenant}} -> {:ok, tenant}
        {:error, :tenant, changeset, _} -> {:error, changeset}
      end
    else
      Repo.delete(tenant)
    end
  end

  def change_tenant(%Tenant{} = tenant, attrs \\ %{}) do
    Tenant.changeset(tenant, attrs)
  end
end
