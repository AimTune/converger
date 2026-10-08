# Excluded unless asked for:
# - :benchmark tests (seeded, slow): `--include benchmark`
# - live storage emulator tests (MinIO, Azurite): `--only` / `--include`
ExUnit.start(exclude: [:benchmark, :minio, :azurite])
Ecto.Adapters.SQL.Sandbox.mode(Converger.Repo, :manual)
