defmodule ConvergerWeb.ApiKeyJSON do
  @moduledoc "Scoped API keys as JSON, for the manage and admin APIs (ADR-0061)."

  alias Converger.ApiKeys.ApiKey

  def index(%{api_keys: api_keys}), do: %{data: for(key <- api_keys, do: data(key, false))}

  def show(%{api_key: api_key} = assigns) do
    %{data: data(api_key, Map.get(assigns, :include_key, false))}
  end

  @doc "A key as JSON: never its hash; the plaintext key only when `include_key`."
  def data(%ApiKey{} = api_key, include_key) do
    base = %{
      id: api_key.id,
      tenant_id: api_key.tenant_id,
      name: api_key.name,
      prefix: api_key.prefix,
      scopes: api_key.scopes,
      expires_at: api_key.expires_at,
      last_used_at: api_key.last_used_at,
      revoked_at: api_key.revoked_at,
      created_by: api_key.created_by,
      inserted_at: api_key.inserted_at,
      updated_at: api_key.updated_at
    }

    if include_key, do: Map.put(base, :key, api_key.key), else: base
  end
end
