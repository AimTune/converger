defmodule Mix.Tasks.Converger.Archive.Import do
  @shortdoc "Re-imports archived activities/deliveries from object storage"

  @moduledoc """
  Re-imports rows that retention archived to object storage (issue #30,
  `Converger.Archive`) back into `activities` / `deliveries`.

      # every part of a tenant and month (activities, then deliveries)
      mix converger.archive.import --tenant 6f1c... --month 2025-01

      # one object from the configured archive storage
      mix converger.archive.import --key archive/6f1c.../2025-01/activities-00001.jsonl.gz

      # a local file (e.g. downloaded from the bucket)
      mix converger.archive.import --file ./activities-00001.jsonl.gz

  Options:

    * `--table activities|deliveries` - the target table when the file name
      does not start with it

  Missing monthly partitions are created. Rows that already exist are
  skipped, so an import can be repeated. Objects listed in `archive_parts`
  are checked against their recorded SHA-256 before import.

  Re-imported rows are subject to retention again: raise the tenant's
  `retention_days` first if they should stay, or import into a separate
  database. In a release (no Mix) use `Converger.Release.import_archive/1`.
  """
  use Mix.Task

  @switches [tenant: :string, month: :string, key: :string, file: :string, table: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    Mix.Task.run("app.start")

    case Converger.Archive.import(opts) do
      {:ok, stats} ->
        Mix.shell().info("Imported: #{inspect(stats)}")

      {:error, :missing_source} ->
        Mix.raise(
          "Give --tenant and --month, --key or --file (see mix help converger.archive.import)"
        )

      {:error, reason} ->
        Mix.raise("Import failed: #{inspect(reason)}")
    end
  end
end
