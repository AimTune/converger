defmodule Mix.Tasks.Converger.Openapi do
  @shortdoc "Writes (or checks) priv/static/openapi.json"
  @moduledoc """
  Writes the OpenAPI 3.1 document (`ConvergerWeb.ApiSpec.to_json/0`) to
  `priv/static/openapi.json` (ADR-0050). `mix openapi.spec.json` is an alias
  of this task.

      $ mix openapi.spec.json            # regenerate the committed file
      $ mix openapi.spec.json --check    # fail when the file is out of date (CI)
      $ mix converger.openapi --output path/to/openapi.json

  Options:

    * `--check` - compare instead of writing; exits non-zero on drift.
    * `--output` - the file (default `priv/static/openapi.json`).
  """
  use Mix.Task

  @default_output "priv/static/openapi.json"

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} =
      OptionParser.parse(argv, strict: [check: :boolean, output: :string])

    Mix.Task.run("app.config")

    output = Keyword.get(opts, :output, @default_output)
    json = ConvergerWeb.ApiSpec.to_json()

    if Keyword.get(opts, :check, false) do
      check(output, json)
    else
      File.mkdir_p!(Path.dirname(output))
      File.write!(output, json)
      Mix.shell().info("Wrote #{output}")
    end
  end

  defp check(output, json) do
    case File.read(output) do
      {:ok, ^json} ->
        Mix.shell().info("#{output} is up to date")

      {:ok, _other} ->
        Mix.raise("#{output} is out of date: run `mix openapi.spec.json` and commit the result")

      {:error, reason} ->
        Mix.raise("Could not read #{output}: #{:file.format_error(reason)}")
    end
  end
end
