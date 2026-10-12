defmodule Converger.Repo do
  use Ecto.Repo,
    otp_app: :converger,
    adapter: Ecto.Adapters.Postgres

  # Tests only (config/test.exs): `Converger.RepoFaults` makes chosen queries
  # raise DBConnection.ConnectionError, as when the pool is saturated.
  if Application.compile_env(:converger, :repo_faults, false) do
    @impl true
    def prepare_query(_operation, query, opts) do
      Converger.RepoFaults.check!(query)
      {query, opts}
    end
  end
end
