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

  @default_rotation_grace_period 24 * 60 * 60

  @doc """
  Looks up a tenant by API key. Keys are stored as SHA-256 digests; a
  previous key is accepted until its grace period expires.
  """
  def get_tenant_by_api_key(api_key) when is_binary(api_key) and api_key != "" do
    hash = Converger.Secrets.hash(api_key)
    now = DateTime.utc_now()

    from(t in Tenant,
      where:
        t.api_key_hash == ^hash or
          (t.previous_api_key_hash == ^hash and t.previous_api_key_expires_at > ^now),
      limit: 1
    )
    |> Repo.one()
  end

  def get_tenant_by_api_key(_api_key), do: nil

  @doc """
  Generates a new API key for the tenant. The returned tenant carries the
  plaintext key in its virtual `api_key` field (shown once). The old key
  remains valid for `:grace_period` seconds (default 24h, configurable via
  `config :converger, :api_key_rotation_grace_period`).
  """
  def rotate_api_key(%Tenant{} = tenant, opts \\ []) do
    grace =
      Keyword.get_lazy(opts, :grace_period, fn ->
        Application.get_env(
          :converger,
          :api_key_rotation_grace_period,
          @default_rotation_grace_period
        )
      end)

    expires_at = DateTime.add(DateTime.utc_now(), grace, :second)
    changeset = Tenant.rotate_api_key_changeset(tenant, expires_at)

    case Keyword.get(opts, :actor) do
      nil ->
        Repo.update(changeset)

      actor ->
        Multi.new()
        |> Multi.update(:tenant, changeset)
        |> Multi.insert(:audit_log, fn %{tenant: updated} ->
          AuditLogs.build_audit_log_entry(%{
            actor_type: actor.type,
            actor_id: actor.id,
            action: "rotate_api_key",
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
    end
  end

  def get_tenant_by_name(name) when is_binary(name) do
    Repo.get_by(Tenant, name: name)
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
