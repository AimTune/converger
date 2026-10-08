# Chaos harness fixtures. Evaluated on the running app node through
# `bin/converger rpc` (see run.sh), with the bindings `rest`, `ws` (number of
# conversations per transport) and `sink_url`. Prints one JSON line.
#
# Not a test file: ExUnit only loads *_test.exs.

alias Converger.Auth.Token
alias Converger.{Channels, Conversations, Tenants}

suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

{:ok, tenant} = Tenants.create_tenant(%{name: "chaos-#{suffix}"})

# The driver deliberately exceeds the default 100 activities/s per tenant.
{:ok, _} =
  Tenants.update_tenant_limits(tenant, %{
    "activity_create" => %{"limit" => 100_000, "scale_ms" => 1_000}
  })

{:ok, channel} =
  Channels.create_channel(%{
    name: "chaos-webhook-#{suffix}",
    tenant_id: tenant.id,
    type: "webhook",
    mode: "outbound",
    config: %{"url" => sink_url}
  })

new_conversation = fn ->
  {:ok, conversation} =
    Conversations.create_conversation(%{tenant_id: tenant.id, channel_id: channel.id})

  conversation
end

rest_conversations = for _ <- 1..rest//1, do: new_conversation.().id

ws_conversations =
  for i <- 1..ws//1 do
    conversation = new_conversation.()
    {:ok, token, _claims} = Token.generate_token(conversation, tenant, "chaos-ws-#{i}")
    %{id: conversation.id, token: token}
  end

IO.puts(
  Jason.encode!(%{
    tenant_id: tenant.id,
    api_key: tenant.api_key,
    channel_id: channel.id,
    rest_conversations: rest_conversations,
    ws_conversations: ws_conversations
  })
)
