# Live storage emulator tests (MinIO, Azurite) run only with --only / --include.
ExUnit.start(exclude: [:minio, :azurite])
Ecto.Adapters.SQL.Sandbox.mode(Converger.Repo, :manual)
