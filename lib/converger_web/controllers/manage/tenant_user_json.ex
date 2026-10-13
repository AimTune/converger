defmodule ConvergerWeb.Manage.TenantUserJSON do
  alias Converger.Accounts.TenantUser

  def index(%{users: users}), do: %{data: Enum.map(users, &data/1)}

  def show(%{user: user}), do: %{data: data(user)}

  @doc "A portal user as JSON: never the password hash or TOTP secret."
  def data(%TenantUser{} = user) do
    %{
      id: user.id,
      tenant_id: user.tenant_id,
      email: user.email,
      name: user.name,
      role: user.role,
      status: user.status,
      totp_enabled: not is_nil(user.totp_enabled_at),
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end
end
