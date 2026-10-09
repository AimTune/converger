# Excluded unless asked for:
# - :benchmark tests (seeded, slow): `--include benchmark`
# - live storage emulator tests (MinIO, Azurite): `--only` / `--include`
ExUnit.start(exclude: [:benchmark, :minio, :azurite])

# activities/deliveries are partitioned by month (issue #30). Tests backdate
# rows to 2024, so make sure those months exist, committed outside the
# sandbox (the migration only creates the current and next months).
Ecto.Adapters.SQL.Sandbox.checkout(Converger.Repo, sandbox: false)
Converger.Partitions.ensure_partitions(from: ~D[2024-01-01])
Ecto.Adapters.SQL.Sandbox.checkin(Converger.Repo)

Ecto.Adapters.SQL.Sandbox.mode(Converger.Repo, :manual)
