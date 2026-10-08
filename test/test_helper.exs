# :benchmark tests (seeded, slow) run only with `--include benchmark`.
ExUnit.start(exclude: [:benchmark])
Ecto.Adapters.SQL.Sandbox.mode(Converger.Repo, :manual)
