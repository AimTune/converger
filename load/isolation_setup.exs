# Fixtures of the dead_channel scenario (epic #59: "one dead channel does not
# degrade other tenants"). Evaluated on a running app node through
# `bin/converger rpc` (see load/run.sh) with the bindings:
#
#   * `conversations` - conversations of the healthy tenant
#   * `mock_url` - base URL of load/mock_provider
#   * `dead_tier` - tier of the dead tenant (`default` unless LOAD_DEAD_TIER)
#
# By default both tenants are on the default tier, so their deliveries share
# one Oban queue, the worst case for isolation (ADR-0031):
#
#   * tenant "dead": one outbound webhook channel pointing at the mock
#     provider's /hook/hang-dead, which accepts the request and never answers
#     (every attempt runs into the adapter timeout). load/isolation_backlog.exs
#     gives it a backlog.
#   * tenant "healthy": one outbound webhook channel on /hook/healthy and
#     `conversations` conversations that load/dead_channel.js posts to.
#
# Prints one JSON line. Not a test file: ExUnit only loads *_test.exs.

alias Converger.{Channels, Conversations, Tenants}

suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
unlimited = %{"limit" => 1_000_000, "scale_ms" => 1_000}

tenant_with_channel = fn name, path, tier ->
  {:ok, tenant} = Tenants.create_tenant(%{name: "load-#{name}-#{suffix}", tier: tier})
  {:ok, _} = Tenants.update_tenant_limits(tenant, %{"activity_create" => unlimited})

  {:ok, channel} =
    Channels.create_channel(%{
      name: "load-#{name}-#{suffix}",
      tenant_id: tenant.id,
      type: "webhook",
      mode: "outbound",
      config: %{"url" => "#{mock_url}/hook/#{path}"}
    })

  {tenant, channel}
end

{dead_tenant, dead_channel} = tenant_with_channel.("dead", "hang-dead", dead_tier)
{healthy_tenant, healthy_channel} = tenant_with_channel.("healthy", "healthy", "default")

# Several conversations, so the backlog is not serialised on one
# conversation lock while it is created.
dead_conversations =
  for _ <- 1..20 do
    {:ok, conversation} =
      Conversations.create_conversation(%{tenant_id: dead_tenant.id, channel_id: dead_channel.id})

    conversation.id
  end

healthy_conversations =
  for _ <- 1..conversations//1 do
    {:ok, conversation} =
      Conversations.create_conversation(%{
        tenant_id: healthy_tenant.id,
        channel_id: healthy_channel.id
      })

    %{id: conversation.id}
  end

IO.puts(
  Jason.encode!(%{
    # lib/converger.js reads `api_key` and `conversations` (the healthy tenant).
    api_key: healthy_tenant.api_key,
    conversations: healthy_conversations,
    healthy: %{tenant_id: healthy_tenant.id, channel_id: healthy_channel.id, path: "healthy"},
    dead: %{
      tenant_id: dead_tenant.id,
      channel_id: dead_channel.id,
      conversation_ids: dead_conversations,
      path: "hang-dead"
    },
    tier: healthy_tenant.tier,
    dead_tier: dead_tenant.tier,
    # For load/run.sh (sed): unique key names.
    dead_channel_id: dead_channel.id,
    healthy_channel_id: healthy_channel.id
  })
)
