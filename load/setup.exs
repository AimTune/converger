# Load harness fixtures. Evaluated on a running app node through
# `bin/converger rpc` (see load/run.sh) with the bindings:
#
#   * `conversations` - conversations for the e2e and reconnect scenarios
#   * `tokens_per_conversation` - socket tokens per conversation (one per
#     subscriber, so each socket is its own participant)
#   * `idle_conversations` - conversations the idle sockets spread over
#   * `targets` - outbound webhook channels the inbound burst fans out to
#   * `mock_url` - base URL of load/mock_provider
#
# It also subscribes a platform event webhook to `activity.created` on the
# mock provider (`/hook/backbone`): every activity goes through the event
# backbone (issue #66) to that subscriber, which is the backbone zero-loss
# check (every stored activity observed once, see load/results.js).
#
# Prints one JSON line. Not a test file: ExUnit only loads *_test.exs.

alias Converger.Auth.ConvergerToken
alias Converger.{Channels, Conversations, RoutingRules, Tenants, Webhooks}

suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

{:ok, tenant} = Tenants.create_tenant(%{name: "load-#{suffix}"})

# The scenarios deliberately run far above the per-tenant defaults: the
# benchmark measures the system, not the rate limiter.
unlimited = %{"limit" => 1_000_000, "scale_ms" => 1_000}

{:ok, _} =
  Tenants.update_tenant_limits(tenant, %{
    "activity_create" => unlimited,
    "inbound" => unlimited,
    "token_generate" => unlimited
  })

webhook_channel = fn name, mode, path ->
  {:ok, channel} =
    Channels.create_channel(%{
      name: "load-#{name}-#{suffix}",
      tenant_id: tenant.id,
      type: "webhook",
      mode: mode,
      config: %{"url" => "#{mock_url}/hook/#{path}"}
    })

  channel
end

# REST -> WS fan-out and reconnect scenarios: conversations on an outbound
# webhook channel, so every activity is also delivered to the mock provider.
fanout = webhook_channel.("fanout", "outbound", "fanout")

conversation_with_tokens = fn channel, count, prefix ->
  {:ok, conversation} =
    Conversations.create_conversation(%{tenant_id: tenant.id, channel_id: channel.id})

  tokens =
    for i <- 1..count//1 do
      {:ok, token, _claims} =
        ConvergerToken.generate_conversation_token(channel, conversation.id,
          user_id: "#{prefix}-#{String.slice(conversation.id, 0, 8)}-#{i}"
        )

      token
    end

  %{id: conversation.id, tokens: tokens}
end

e2e =
  for _ <- 1..conversations//1,
      do: conversation_with_tokens.(fanout, tokens_per_conversation, "sub")

idle =
  for _ <- 1..idle_conversations//1,
      do: conversation_with_tokens.(fanout, 1, "idle")

# Inbound burst: a duplex ingress channel routed to `targets` outbound
# channels, each delivering to its own mock provider path.
ingress = webhook_channel.("ingress", "duplex", "ingress")

target_channels =
  for i <- 1..targets//1, do: webhook_channel.("target-#{i}", "outbound", "target-#{i}")

if target_channels != [] do
  {:ok, _rule} =
    RoutingRules.create_routing_rule(%{
      name: "load-burst-#{suffix}",
      tenant_id: tenant.id,
      source_channel_id: ingress.id,
      target_channel_ids: Enum.map(target_channels, & &1.id)
    })
end

{:ok, backbone_subscription} =
  Webhooks.create_subscription(tenant.id, %{
    "url" => "#{mock_url}/hook/backbone",
    "events" => ["activity.created"],
    "description" => "load harness backbone zero-loss check"
  })

IO.puts(
  Jason.encode!(%{
    tenant_id: tenant.id,
    backbone_subscription_id: backbone_subscription.id,
    api_key: tenant.api_key,
    fanout_channel_id: fanout.id,
    conversations: e2e,
    idle_conversations: idle,
    ingress: %{id: ingress.id, secret: ingress.secret},
    targets:
      target_channels
      |> Enum.with_index(1)
      |> Enum.map(fn {channel, i} -> %{id: channel.id, path: "target-#{i}"} end)
  })
)
