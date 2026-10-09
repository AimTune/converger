# Excluded unless asked for:
# - :benchmark tests (seeded, slow): `--include benchmark`
# - live storage emulator tests (MinIO, Azurite): `--only` / `--include`
#
# assert_receive / assert_reply / assert_push wait up to 1 s (ExUnit's
# default is 100 ms). Channel and pipeline tests wait for messages from other
# processes; on a loaded CI runner 100 ms was occasionally too short and the
# tests flaked. Passing tests are not slowed down: the assertion returns as
# soon as the message arrives. refute_receive keeps its own 100 ms default.
ExUnit.start(exclude: [:benchmark, :minio, :azurite], assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(Converger.Repo, :manual)
