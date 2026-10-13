defmodule Converger.Accounts.Audit do
  @moduledoc false
  # Audit log entries for account security events (2FA, password reset,
  # session revocation) of admin and tenant users.

  alias Converger.Accounts.{AdminUser, TenantUser}
  alias Converger.AuditLogs

  @doc "The actor for an action a user performs on their own account."
  def self_actor(%AdminUser{id: id}), do: %{type: "admin", id: id}
  def self_actor(%TenantUser{id: id}), do: %{type: "tenant_user", id: id}

  @doc "Builds the audit log changeset of `action` on `user`."
  def entry(user, actor, action, changes \\ %{}) do
    AuditLogs.build_audit_log_entry(%{
      tenant_id: tenant_id(user),
      actor_type: actor.type,
      actor_id: to_string(actor.id),
      action: action,
      resource_type: resource_type(user),
      resource_id: user.id,
      changes: changes
    })
  end

  @doc "Inserts the audit log entry of `action` on `user`."
  def log(user, actor, action, changes \\ %{}) do
    user |> entry(actor, action, changes) |> Converger.Repo.insert()
  end

  defp tenant_id(%TenantUser{tenant_id: tenant_id}), do: tenant_id
  defp tenant_id(_), do: nil

  defp resource_type(%AdminUser{}), do: "admin_user"
  defp resource_type(%TenantUser{}), do: "tenant_user"
end
