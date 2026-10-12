# Fixtures for the @converger/client e2e test (packages/client-ts/test/e2e).
# Run with `mix run packages/client-ts/test/e2e/setup.exs` against the e2e
# database; prints one JSON line with a channel secret.

alias Converger.{Channels, Tenants}

suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
{:ok, tenant} = Tenants.create_tenant(%{name: "sdk-e2e-#{suffix}"})

{:ok, channel} =
  Channels.create_channel(%{
    name: "sdk-e2e-#{suffix}",
    tenant_id: tenant.id,
    type: "websocket",
    mode: "duplex",
    status: "active"
  })

IO.puts("E2E_FIXTURES " <> Jason.encode!(%{tenant_id: tenant.id, channel_id: channel.id, secret: channel.secret}))
