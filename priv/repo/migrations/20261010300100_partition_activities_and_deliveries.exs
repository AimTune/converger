defmodule Converger.Repo.Migrations.PartitionActivitiesAndDeliveries do
  use Ecto.Migration

  # Issue #30, ADR-0033. Converts activities and deliveries into monthly range
  # partitioned tables (create partitioned shadow tables, copy in batches,
  # swap); see Converger.Partitions.Conversion.
  #
  # MAINTENANCE WINDOW on existing installations: the swap locks both tables
  # and old releases cannot write the new deliveries columns. Fresh and small
  # installations convert in seconds. Installations with more than
  # PARTITION_MAX_INLINE_ROWS (default 1,000,000) activities must run the
  # online copy first:
  #
  #     bin/converger eval "Converger.Release.prepare_partitioning()"
  #
  # See docs/operations/migrations.md, "Partitioning activities and
  # deliveries". The copy commits batch by batch, hence no DDL transaction;
  # the swap is a single transaction of its own.
  @disable_ddl_transaction true

  def up do
    Converger.Partitions.Conversion.run(repo())
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "activities/deliveries partitioning cannot be rolled back automatically. " <>
          "Restore the pre-upgrade backup, or rename activities_legacy/deliveries_legacy back " <>
          "(they are kept on populated installations) accepting the loss of newer rows."
  end
end
