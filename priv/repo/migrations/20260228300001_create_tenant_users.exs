defmodule Converger.Repo.Migrations.CreateTenantUsers do
  use Ecto.Migration

  def change do
    create table(:tenant_users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :password_hash, :string, null: false
      add :name, :string, null: false
      add :role, :string, null: false, default: "member"
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenant_users, [:tenant_id, :email])
    create index(:tenant_users, [:tenant_id])
  end
end
