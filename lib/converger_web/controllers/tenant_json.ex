defmodule ConvergerWeb.TenantJSON do
  @moduledoc "Tenants as JSON, for the settings and admin APIs (ADR-0061)."

  alias Converger.Tenants.Tenant

  def index(%{tenants: tenants}), do: %{data: for(tenant <- tenants, do: data(tenant, false))}

  def show(%{tenant: tenant} = assigns) do
    %{data: data(tenant, Map.get(assigns, :include_api_key, false))}
  end

  @doc """
  A tenant as JSON. Never the key hashes; the plaintext primary key only
  when `include_api_key` (right after create or rotation).
  """
  def data(%Tenant{} = tenant, include_api_key) do
    base = %{
      id: tenant.id,
      name: tenant.name,
      status: tenant.status,
      tier: tenant.tier,
      retention_days: tenant.retention_days,
      alert_webhook_url: tenant.alert_webhook_url,
      allowed_upload_types: tenant.allowed_upload_types,
      limits: tenant.limits || %{},
      api_key_prefix: tenant.api_key_prefix,
      inserted_at: tenant.inserted_at,
      updated_at: tenant.updated_at
    }

    if include_api_key, do: Map.put(base, :api_key, tenant.api_key), else: base
  end
end
