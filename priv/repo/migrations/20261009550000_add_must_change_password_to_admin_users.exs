defmodule Converger.Repo.Migrations.AddMustChangePasswordToAdminUsers do
  use Ecto.Migration

  # Expand-only and zero-downtime: adding a column with a constant default is
  # a metadata-only change on Postgres 11+ (no table rewrite), and code that
  # does not know about the column keeps working during a rolling deploy.
  def change do
    alter table(:admin_users) do
      add :must_change_password, :boolean, null: false, default: false
    end
  end
end
