# Fixtures for the @converger/agent e2e test (packages/agent-ts/test/e2e):
# a tenant, a `websocket` widget channel (the end user), a `websocket` bot
# channel (the agent) and a routing rule widget -> bot.
#
#   mix run packages/agent-ts/test/e2e/setup.exs
#
# Prints the environment the test reads (CONVERGER_CHANNEL_SECRET is the bot
# channel's secret, CONVERGER_USER_CHANNEL_SECRET the widget's).

alias Converger.{Channels, RoutingRules, Tenants}

suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
{:ok, tenant} = Tenants.create_tenant(%{name: "agent-e2e-#{suffix}"})

channel = fn name ->
  {:ok, channel} =
    Channels.create_channel(%{
      name: "#{name}-#{suffix}",
      tenant_id: tenant.id,
      type: "websocket",
      mode: "duplex",
      status: "active"
    })

  channel
end

widget = channel.("agent-e2e-widget")
bot = channel.("agent-e2e-bot")

{:ok, _rule} =
  RoutingRules.create_routing_rule(%{
    name: "agent-e2e widget to bot",
    tenant_id: tenant.id,
    source_channel_id: widget.id,
    target_channel_ids: [bot.id]
  })

IO.puts("CONVERGER_CHANNEL_SECRET=#{bot.secret}")
IO.puts("CONVERGER_USER_CHANNEL_SECRET=#{widget.secret}")
