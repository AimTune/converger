defmodule Converger.Accounts do
  @moduledoc """
  The Accounts context for admin and tenant user management.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Converger.Repo
  alias Converger.Accounts.{AdminUser, TenantUser}
  alias Converger.AuditLogs
  alias Converger.AuditLogs.Changes

  # --- Admin Users ---

  def list_admin_users do
    Repo.all(from u in AdminUser, order_by: [desc: u.inserted_at])
  end

  def get_admin_user!(id), do: Repo.get!(AdminUser, id)

  def get_admin_user_by_email(email) when is_binary(email) do
    Repo.get_by(AdminUser, email: email)
  end

  def authenticate_admin(email, password) do
    user = get_admin_user_by_email(email)

    cond do
      user && user.status == "active" && AdminUser.valid_password?(user, password) ->
        {:ok, user}

      user && user.status != "active" ->
        {:error, :inactive}

      true ->
        AdminUser.valid_password?(nil, "")
        {:error, :invalid_credentials}
    end
  end

  def create_admin_user(attrs, actor \\ nil) do
    changeset = AdminUser.registration_changeset(%AdminUser{}, attrs)

    if actor do
      Multi.new()
      |> Multi.insert(:admin_user, changeset)
      |> Multi.insert(:audit_log, fn %{admin_user: user} ->
        AuditLogs.build_audit_log_entry(%{
          actor_type: actor.type,
          actor_id: actor.id,
          action: "create",
          resource_type: "admin_user",
          resource_id: user.id,
          changes: Changes.for_create(user)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{admin_user: user}} -> {:ok, user}
        {:error, :admin_user, changeset, _} -> {:error, changeset}
      end
    else
      Repo.insert(changeset)
    end
  end

  def update_admin_user(%AdminUser{} = user, attrs, actor \\ nil) do
    changeset = AdminUser.changeset(user, attrs)

    if actor do
      Multi.new()
      |> Multi.update(:admin_user, changeset)
      |> Multi.insert(:audit_log, fn %{admin_user: updated} ->
        AuditLogs.build_audit_log_entry(%{
          actor_type: actor.type,
          actor_id: actor.id,
          action: "update",
          resource_type: "admin_user",
          resource_id: user.id,
          changes: Changes.for_update(user, updated)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{admin_user: updated}} -> {:ok, updated}
        {:error, :admin_user, changeset, _} -> {:error, changeset}
      end
    else
      Repo.update(changeset)
    end
  end

  def delete_admin_user(%AdminUser{} = user, actor \\ nil) do
    if actor do
      Multi.new()
      |> Multi.insert(:audit_log, fn _ ->
        AuditLogs.build_audit_log_entry(%{
          actor_type: actor.type,
          actor_id: actor.id,
          action: "delete",
          resource_type: "admin_user",
          resource_id: user.id,
          changes: Changes.for_delete(user)
        })
      end)
      |> Multi.delete(:admin_user, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{admin_user: user}} -> {:ok, user}
        {:error, :admin_user, changeset, _} -> {:error, changeset}
      end
    else
      Repo.delete(user)
    end
  end

  def change_admin_user(%AdminUser{} = user, attrs \\ %{}) do
    AdminUser.changeset(user, attrs)
  end

  # --- Tenant Users ---

  def list_tenant_users(tenant_id) do
    from(u in TenantUser,
      where: u.tenant_id == ^tenant_id,
      order_by: [desc: u.inserted_at],
      preload: [:tenant]
    )
    |> Repo.all()
  end

  def list_all_tenant_users do
    from(u in TenantUser, order_by: [desc: u.inserted_at], preload: [:tenant])
    |> Repo.all()
  end

  def get_tenant_user!(id) do
    Repo.get!(TenantUser, id) |> Repo.preload(:tenant)
  end

  def get_tenant_user_by_email_and_tenant(email, tenant_id) do
    Repo.get_by(TenantUser, email: email, tenant_id: tenant_id)
  end

  def authenticate_tenant_user(email, password, tenant_id) do
    user = get_tenant_user_by_email_and_tenant(email, tenant_id)

    cond do
      user && user.status == "active" && TenantUser.valid_password?(user, password) ->
        {:ok, Repo.preload(user, :tenant)}

      user && user.status != "active" ->
        {:error, :inactive}

      true ->
        TenantUser.valid_password?(nil, "")
        {:error, :invalid_credentials}
    end
  end

  def authenticate_tenant_user_by_name(email, password, tenant_name) do
    alias Converger.Tenants

    case Tenants.get_tenant_by_name(tenant_name) do
      %{id: tenant_id, status: "active"} ->
        authenticate_tenant_user(email, password, tenant_id)

      %{status: _} ->
        TenantUser.valid_password?(nil, "")
        {:error, :invalid_credentials}

      nil ->
        TenantUser.valid_password?(nil, "")
        {:error, :invalid_credentials}
    end
  end

  def create_tenant_user(attrs, actor \\ nil) do
    changeset = TenantUser.registration_changeset(%TenantUser{}, attrs)

    if actor do
      Multi.new()
      |> Multi.insert(:tenant_user, changeset)
      |> Multi.insert(:audit_log, fn %{tenant_user: user} ->
        AuditLogs.build_audit_log_entry(%{
          tenant_id: user.tenant_id,
          actor_type: actor.type,
          actor_id: actor.id,
          action: "create",
          resource_type: "tenant_user",
          resource_id: user.id,
          changes: Changes.for_create(user)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{tenant_user: user}} -> {:ok, Repo.preload(user, :tenant)}
        {:error, :tenant_user, changeset, _} -> {:error, changeset}
      end
    else
      case Repo.insert(changeset) do
        {:ok, user} -> {:ok, Repo.preload(user, :tenant)}
        error -> error
      end
    end
  end

  def update_tenant_user(%TenantUser{} = user, attrs, actor \\ nil) do
    changeset = TenantUser.changeset(user, attrs)

    if actor do
      Multi.new()
      |> Multi.update(:tenant_user, changeset)
      |> Multi.insert(:audit_log, fn %{tenant_user: updated} ->
        AuditLogs.build_audit_log_entry(%{
          tenant_id: user.tenant_id,
          actor_type: actor.type,
          actor_id: actor.id,
          action: "update",
          resource_type: "tenant_user",
          resource_id: user.id,
          changes: Changes.for_update(user, updated)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{tenant_user: updated}} -> {:ok, Repo.preload(updated, :tenant)}
        {:error, :tenant_user, changeset, _} -> {:error, changeset}
      end
    else
      case Repo.update(changeset) do
        {:ok, user} -> {:ok, Repo.preload(user, :tenant)}
        error -> error
      end
    end
  end

  def delete_tenant_user(%TenantUser{} = user, actor \\ nil) do
    if actor do
      Multi.new()
      |> Multi.insert(:audit_log, fn _ ->
        AuditLogs.build_audit_log_entry(%{
          tenant_id: user.tenant_id,
          actor_type: actor.type,
          actor_id: actor.id,
          action: "delete",
          resource_type: "tenant_user",
          resource_id: user.id,
          changes: Changes.for_delete(user)
        })
      end)
      |> Multi.delete(:tenant_user, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{tenant_user: user}} -> {:ok, user}
        {:error, :tenant_user, changeset, _} -> {:error, changeset}
      end
    else
      Repo.delete(user)
    end
  end

  def change_tenant_user(%TenantUser{} = user, attrs \\ %{}) do
    TenantUser.changeset(user, attrs)
  end
end
