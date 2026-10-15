defmodule Converger.ConversationSearchTest do
  use Converger.DataCase, async: true

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{AuditLogs, Conversations, Participants}

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)

    {:ok, alice} =
      Participants.resolve_conversation(channel, %{
        "external_id" => "+15550001111",
        "display_name" => "Alice Example"
      })

    {:ok, bob} =
      Participants.resolve_conversation(channel, %{"external_id" => "bob@example.com"})

    anonymous = conversation_fixture(tenant, channel)
    %{tenant: tenant, alice: alice, bob: bob, anonymous: anonymous}
  end

  defp search(tenant, q) do
    {:ok, page} = Conversations.paginate_conversations(%{"tenant_id" => tenant.id, "q" => q})
    page.entries |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "q matches the participant external id, exactly or by substring", ctx do
    assert search(ctx.tenant, "+15550001111") == [ctx.alice.id]
    assert search(ctx.tenant, "0001") == [ctx.alice.id]
    assert search(ctx.tenant, "EXAMPLE.COM") == [ctx.bob.id]
  end

  test "q matches the participant display name", ctx do
    assert search(ctx.tenant, "alice") == [ctx.alice.id]
  end

  test "q still matches an exact conversation id", ctx do
    assert search(ctx.tenant, ctx.anonymous.id) == [ctx.anonymous.id]
    assert search(ctx.tenant, " #{ctx.bob.id} ") == [ctx.bob.id]
  end

  test "a blank q lists everything and LIKE wildcards match literally", ctx do
    assert length(search(ctx.tenant, "  ")) == 3
    assert search(ctx.tenant, "%") == []
  end

  test "close/reopen with an actor are audited; no-ops are not", %{alice: conversation} do
    actor = %{type: "admin", id: "ops@example.com"}

    {:ok, closed} = Conversations.close_conversation(conversation, actor: actor)
    {:ok, _} = Conversations.close_conversation(closed, actor: actor)
    {:ok, _} = Conversations.reopen_conversation(closed, actor: actor)

    logs = AuditLogs.list_audit_logs(%{"resource_id" => conversation.id})

    assert logs |> Enum.map(& &1.action) |> Enum.sort() == ["close", "reopen"]

    assert Enum.all?(logs, &(&1.resource_type == "conversation" and &1.actor_id == actor.id))

    close = Enum.find(logs, &(&1.action == "close"))

    assert close.changes == %{
             "before" => %{"status" => "active"},
             "after" => %{"status" => "closed"}
           }
  end
end
