defmodule Converger.Repo.Migrations.UpgradeObanJobsToV14 do
  use Ecto.Migration

  # Oban 2.24 refuses to start unless the oban_jobs schema is at version 14.
  def up, do: Oban.Migrations.up(version: 14)

  def down, do: Oban.Migrations.down(version: 12)
end
