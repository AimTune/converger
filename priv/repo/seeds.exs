# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Converger.Repo.insert!(%Converger.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Converger.Accounts

# Create default super_admin user if none exists
if Accounts.list_admin_users() == [] do
  case Accounts.create_admin_user(%{
         email: "admin@converger.local",
         password: "admin123456",
         name: "Super Admin",
         role: "super_admin"
       }) do
    {:ok, user} ->
      IO.puts("Created super_admin user: #{user.email} (password: admin123456)")

    {:error, changeset} ->
      IO.puts("Failed to create super_admin: #{inspect(changeset.errors)}")
  end
end
