defmodule Converger.ApiKeys do
  @moduledoc """
  Tenant API credentials and their scopes (issue #51, ADR-0061).

  A tenant has two kinds of API key, both sent in `x-api-key`:

    * its **primary key** (`tenants.api_key_hash`, issued with the tenant and
      rotated from the admin UI or `POST /api/v1/admin/tenants/:id/rotate_api_key`),
      which has every scope;
    * any number of **scoped keys** (`api_keys`), each with a subset of
      `read`, `write` and `manage`, an optional expiry, revoked rather than
      deleted.

  `authenticate/1` resolves a presented key to `{tenant, credential}`; the
  credential's `id` is the audit actor id (the key id, or the tenant id for
  the primary key).
  """

  import Ecto.Query, warn: false

  alias Converger.ApiKeys.{ApiKey, Credential}
  alias Converger.AuditLogs
  alias Converger.AuditLogs.Changes
  alias Converger.{Repo, Tenants}
  alias Converger.Tenants.Tenant
  alias Ecto.Multi

  # `last_used_at` is written at most once per key per this many seconds.
  @touch_interval 60

  @doc "Every scope."
  def scopes, do: ApiKey.scopes()

  @doc """
  Resolves an `x-api-key` value: a scoped key (active, of an active tenant)
  or a tenant's primary key. Returns `{:ok, tenant, %Credential{}}`,
  `{:error, :inactive_tenant}` or `{:error, :invalid}`.
  """
  def authenticate(key) when is_binary(key) and key != "" do
    hash = Converger.Secrets.hash(key)

    case Repo.one(from k in ApiKey, where: k.key_hash == ^hash, preload: :tenant) do
      %ApiKey{} = api_key -> authenticate_scoped(api_key)
      nil -> authenticate_primary(key)
    end
  end

  def authenticate(_key), do: {:error, :invalid}

  defp authenticate_scoped(%ApiKey{} = api_key) do
    cond do
      not ApiKey.active?(api_key) ->
        {:error, :invalid}

      api_key.tenant.status != "active" ->
        {:error, :inactive_tenant}

      true ->
        touch(api_key)

        {:ok, api_key.tenant,
         %Credential{kind: :api_key, id: api_key.id, api_key: api_key, scopes: api_key.scopes}}
    end
  end

  defp authenticate_primary(key) do
    case Tenants.get_tenant_by_api_key(key) do
      %Tenant{status: "active"} = tenant ->
        {:ok, tenant, %Credential{kind: :primary_key, id: tenant.id, scopes: scopes()}}

      %Tenant{} ->
        {:error, :inactive_tenant}

      nil ->
        {:error, :invalid}
    end
  end

  # Throttled: a busy key does not turn every request into a write.
  defp touch(%ApiKey{id: id, last_used_at: last_used_at}) do
    now = DateTime.utc_now()

    if is_nil(last_used_at) or DateTime.diff(now, last_used_at) >= @touch_interval do
      cutoff = DateTime.add(now, -@touch_interval, :second)

      from(k in ApiKey,
        where: k.id == ^id and (is_nil(k.last_used_at) or k.last_used_at < ^cutoff)
      )
      |> Repo.update_all(set: [last_used_at: now])
    end

    :ok
  end

  @doc "A tenant's scoped keys (revoked ones included), newest first."
  def list_api_keys(tenant_id) do
    from(k in ApiKey,
      where: k.tenant_id == ^tenant_id,
      order_by: [desc: k.inserted_at, desc: k.id]
    )
    |> Converger.Pagination.bounded_all()
  end

  @doc "The tenant's key with `id`, or `nil` (also for a malformed id)."
  def get_api_key(tenant_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(ApiKey, id: uuid, tenant_id: tenant_id)
      :error -> nil
    end
  end

  @doc """
  Issues a scoped key for the tenant. The returned key carries the
  plaintext in its virtual `key` field, shown once. `actor` is
  `%{type, id}`, audited and recorded in `created_by`.
  """
  def create_api_key(tenant_id, attrs, actor) do
    changeset =
      %ApiKey{tenant_id: tenant_id, created_by: "#{actor.type}:#{actor.id}"}
      |> ApiKey.create_changeset(attrs)

    Multi.new()
    |> Multi.insert(:api_key, changeset)
    |> Multi.insert(:audit_log, fn %{api_key: api_key} ->
      audit_entry(api_key, actor, "create", Changes.for_create(%{api_key | key: nil}))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{api_key: api_key}} -> {:ok, api_key}
      {:error, :api_key, changeset, _} -> {:error, changeset}
    end
  end

  @doc "Revokes a key; it stops working at once. Revoking twice is a no-op."
  def revoke_api_key(%ApiKey{revoked_at: %DateTime{}} = api_key, _actor), do: {:ok, api_key}

  def revoke_api_key(%ApiKey{} = api_key, actor) do
    changeset = Ecto.Changeset.change(api_key, revoked_at: DateTime.utc_now())

    Multi.new()
    |> Multi.update(:api_key, changeset)
    |> Multi.insert(:audit_log, fn %{api_key: revoked} ->
      audit_entry(api_key, actor, "revoke", Changes.for_update(api_key, revoked))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{api_key: revoked}} -> {:ok, revoked}
      {:error, :api_key, changeset, _} -> {:error, changeset}
    end
  end

  defp audit_entry(api_key, actor, action, changes) do
    AuditLogs.build_audit_log_entry(%{
      tenant_id: api_key.tenant_id,
      actor_type: actor.type,
      actor_id: actor.id,
      action: action,
      resource_type: "api_key",
      resource_id: api_key.id,
      changes: changes
    })
  end
end
