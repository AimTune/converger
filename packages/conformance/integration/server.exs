# Integration fixtures for the SDK end-to-end tests. Run from the repository
# root against a dev database, with the HTTP listener enabled:
#
#     PHX_SERVER=true mix run --no-halt packages/conformance/integration/server.exs
#
# (or use packages/conformance/integration/run.sh). For every SDK it creates
# a tenant, a `websocket` client channel (its secret issues converger
# tokens) and a `webhook` channel that receives every activity of the client
# channel through a routing rule, pointing at http://127.0.0.1:<port>/webhook,
# where the SDK test listens. It writes the credentials to
# CONVERGER_FIXTURES (default packages/conformance/integration/fixtures.json,
# git-ignored) and keeps serving.

alias Converger.{Channels, RoutingRules, Tenants}

out =
  System.get_env("CONVERGER_FIXTURES") ||
    Path.expand("fixtures.json", __DIR__)

ports = %{"python" => 47_801, "go" => 47_802, "elixir" => 47_803}
suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
unlimited = %{"limit" => 100_000, "scale_ms" => 1_000}

fixtures =
  Map.new(ports, fn {sdk, port} ->
    {:ok, tenant} = Tenants.create_tenant(%{name: "sdk-#{sdk}-#{suffix}"})

    {:ok, tenant} =
      Tenants.update_tenant_limits(tenant, %{
        "activity_create" => unlimited,
        "token_generate" => unlimited
      })

    {:ok, client} =
      Channels.create_channel(%{
        name: "sdk-#{sdk}-client-#{suffix}",
        tenant_id: tenant.id,
        type: "websocket",
        mode: "duplex"
      })

    {:ok, webhook} =
      Channels.create_channel(%{
        name: "sdk-#{sdk}-webhook-#{suffix}",
        tenant_id: tenant.id,
        type: "webhook",
        mode: "outbound",
        config: %{"url" => "http://127.0.0.1:#{port}/webhook"}
      })

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "sdk-#{sdk}-#{suffix}",
        tenant_id: tenant.id,
        source_channel_id: client.id,
        target_channel_ids: [webhook.id]
      })

    {sdk,
     %{
       api_key: tenant.api_key,
       channel_id: client.id,
       channel_secret: client.secret,
       webhook_channel_id: webhook.id,
       webhook_secret: webhook.secret,
       webhook_port: port
     }}
  end)

# Agent SDKs (#67): a `websocket` widget channel (the end user) routed to a
# `websocket` bot channel (the agent, on a channel-scoped socket).
agent_fixture = fn name ->
  {:ok, tenant} = Tenants.create_tenant(%{name: "sdk-#{name}-#{suffix}"})

  {:ok, tenant} =
    Tenants.update_tenant_limits(tenant, %{
      "activity_create" => unlimited,
      "token_generate" => unlimited
    })

  channel = fn role ->
    {:ok, channel} =
      Channels.create_channel(%{
        name: "sdk-#{name}-#{role}-#{suffix}",
        tenant_id: tenant.id,
        type: "websocket",
        mode: "duplex"
      })

    channel
  end

  widget = channel.("widget")
  bot = channel.("bot")

  {:ok, _rule} =
    RoutingRules.create_routing_rule(%{
      name: "sdk-#{name}-widget-to-bot-#{suffix}",
      tenant_id: tenant.id,
      source_channel_id: widget.id,
      target_channel_ids: [bot.id]
    })

  %{
    api_key: tenant.api_key,
    widget_channel_id: widget.id,
    widget_secret: widget.secret,
    bot_channel_id: bot.id,
    bot_secret: bot.secret
  }
end

fixtures = Map.put(fixtures, "agent-python", agent_fixture.("agent-python"))

endpoint = Application.get_env(:converger, ConvergerWeb.Endpoint)
port = get_in(endpoint, [:http, :port]) || 4000

File.write!(
  out,
  Jason.encode!(Map.put(fixtures, "base_url", "http://localhost:#{port}"), pretty: true)
)

IO.puts("SDK integration fixtures written to #{out}")
