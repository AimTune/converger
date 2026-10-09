defmodule Converger.ConversationLifecycleTest do
  use Converger.DataCase, async: false

  alias Converger.{Activities, Conversations}
  alias Ecto.Adapters.SQL.Sandbox

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  defp attrs(conversation, text) do
    %{
      sender: "user-1",
      text: text,
      tenant_id: conversation.tenant_id,
      conversation_id: conversation.id
    }
  end

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    %{tenant: tenant, channel: channel, conversation: conversation_fixture(tenant, channel)}
  end

  test "open?/1 and ensure_open/1", %{conversation: conversation} do
    assert Conversations.open?(conversation)
    assert :ok = Conversations.ensure_open(conversation)

    {:ok, closed} = Conversations.close_conversation(conversation)
    refute Conversations.open?(closed)
    assert {:error, :conversation_closed} = Conversations.ensure_open(closed)
  end

  test "closed conversations reject activities; reopened ones accept them again", %{
    conversation: conversation
  } do
    {:ok, a1} = Activities.create_activity(attrs(conversation, "before"))

    assert {:ok, %{status: "closed"}} = Conversations.close_conversation(conversation)

    assert {:error, :conversation_closed} =
             Activities.create_activity(attrs(conversation, "after close"))

    assert {:error, :conversation_closed} =
             Activities.create_client_activity(%{"text" => "client"}, %{
               tenant_id: conversation.tenant_id,
               conversation_id: conversation.id,
               sender: "user-1"
             })

    assert {:ok, %{status: "active"}} = Conversations.reopen_conversation(conversation)
    {:ok, a2} = Activities.create_activity(attrs(conversation, "after reopen"))

    a1_id = a1.id
    a2_id = a2.id

    assert [
             %{id: ^a1_id},
             %{type: "conversationUpdate", sender: "system", metadata: closed_meta} = closed_ev,
             %{type: "conversationUpdate", metadata: reopened_meta},
             %{id: ^a2_id}
           ] = Activities.list_activities_for_conversation(conversation.id)

    assert closed_meta == %{
             "event" => "conversation_closed",
             "status" => "closed",
             "reason" => "manual"
           }

    assert reopened_meta == %{
             "event" => "conversation_reopened",
             "status" => "active",
             "reason" => "manual"
           }

    assert closed_ev.seq == a1.seq + 1
    # Rejected inserts did not consume a seq.
    assert a2.seq == a1.seq + 3
    assert Conversations.lifecycle_event?(closed_ev)
    refute Conversations.lifecycle_event?(a1)
  end

  test "close and reopen are idempotent", %{conversation: conversation} do
    {:ok, _} = Conversations.close_conversation(conversation)
    {:ok, %{status: "closed"}} = Conversations.close_conversation(conversation)
    assert length(Activities.list_activities_for_conversation(conversation.id)) == 1

    {:ok, _} = Conversations.reopen_conversation(conversation)
    {:ok, %{status: "active"}} = Conversations.reopen_conversation(conversation)
    assert length(Activities.list_activities_for_conversation(conversation.id)) == 2
  end

  test "an idempotent retry of an already accepted activity still succeeds after close", %{
    conversation: conversation
  } do
    attrs = Map.put(attrs(conversation, "once"), :idempotency_key, "k-1")
    {:ok, original} = Activities.create_activity(attrs)
    {:ok, _} = Conversations.close_conversation(conversation)

    assert {:ok, %{id: id}} = Activities.create_activity(attrs)
    assert id == original.id
  end

  test "adding an activity bumps the conversation's updated_at", %{conversation: conversation} do
    old = DateTime.utc_now() |> DateTime.add(-48, :hour)

    from(c in Conversations.Conversation, where: c.id == ^conversation.id)
    |> Repo.update_all(set: [updated_at: old])

    {:ok, _} = Activities.create_activity(attrs(conversation, "hi"))

    assert DateTime.compare(Repo.reload!(conversation).updated_at, DateTime.add(old, 1, :hour)) ==
             :gt
  end

  test "status is validated", %{conversation: conversation} do
    assert {:error, changeset} =
             Conversations.update_conversation(conversation, %{status: "bogus"})

    assert %{status: ["is invalid"]} = errors_on(changeset)
  end

  describe "close racing with inserts" do
    # Real connections (no sandbox) so that the row lock actually serialises
    # the close with the concurrent inserts.
    @tag timeout: 120_000
    test "every activity is either committed before the close event or rejected" do
      {tenant, conversation} =
        Sandbox.unboxed_run(Repo, fn ->
          tenant = tenant_fixture()
          channel = channel_fixture(tenant)
          {tenant, conversation_fixture(tenant, channel)}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(
            from(l in Converger.AuditLogs.AuditLog, where: l.tenant_id == ^tenant.id)
          )

          # Activities are purged by the PurgeWorker job delete_tenant enqueues.
          {:ok, _} = Converger.Tenants.delete_tenant(tenant)
        end)
      end)

      results =
        [:close | Enum.to_list(1..30)]
        |> Task.async_stream(
          fn
            :close ->
              Sandbox.unboxed_run(Repo, fn ->
                {:ok, _} = Conversations.close_conversation(conversation)
                :closed
              end)

            i ->
              Sandbox.unboxed_run(Repo, fn ->
                Activities.create_activity(attrs(conversation, "msg #{i}"))
              end)
          end,
          max_concurrency: 31,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      accepted = for {:ok, a} <- results, do: a
      rejected = for {:error, :conversation_closed} <- results, do: :rejected

      assert length(accepted) + length(rejected) == 30

      activities =
        Sandbox.unboxed_run(Repo, fn ->
          Activities.list_activities_for_conversation(conversation.id)
        end)

      # The close event is the last activity and every accepted one precedes it.
      assert %{type: "conversationUpdate"} = List.last(activities)
      assert length(activities) == length(accepted) + 1
      assert Enum.map(activities, & &1.seq) == Enum.to_list(1..length(activities))
    end
  end
end
