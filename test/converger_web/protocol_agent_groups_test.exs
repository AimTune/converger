defmodule ConvergerWeb.ProtocolAgentGroupsTest do
  @moduledoc """
  Agent groups (`hello.group`, docs/protocol/v1.md section 10, ADR-0069) over
  real sockets: several agent processes behind one `websocket` bot channel
  share the conversations routed to it. Each user turn reaches exactly one
  member (affinity: always the same one while the membership is stable); a
  member that leaves hands its unanswered turns to the new owner; a member
  that joins takes only turns committed after it became eligible. The turn
  lock is the bot's: a bot's `busy` error is relayed to the end user.

  The settle delay is 100 ms in the test configuration.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Auth.ConvergerToken
  alias Converger.{Inbound, RoutingRules}
  alias ConvergerWeb.Protocol.GroupMembership
  alias ConvergerWeb.ProtocolClient, as: Client

  @moduletag :protocol

  # Longer than the test settle delay (group_settle_ms: 100).
  @settle 200

  setup do
    tenant = tenant_fixture()
    widget = channel_fixture(tenant)
    bot = channel_fixture(tenant)

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "widget to bot",
        tenant_id: tenant.id,
        source_channel_id: widget.id,
        target_channel_ids: [bot.id]
      })

    conversations = for _ <- 1..12, do: conversation_fixture(tenant, widget)

    %{
      tenant: tenant,
      widget: widget,
      bot: bot,
      conversations: conversations,
      port: Client.start_server()
    }
  end

  defp agent(ctx, name) do
    {:ok, token, _} = ConvergerToken.generate_token(ctx.bot, scope: "channel", user_id: name)
    {:ok, client} = Client.connect(ctx.port, headers: [{"authorization", "Bearer #{token}"}])
    client = Client.push(client, %{"type" => "hello", "group" => "workers"})
    assert {%{"type" => "welcome"}, client} = Client.recv(client)
    client
  end

  # A user turn on the widget channel, routed to the bot channel.
  defp turn(ctx, conversation, text) do
    message = %{"type" => "message", "sender" => "alice", "text" => text}

    {:created, activity} =
      Inbound.receive_message(ctx.widget, message, conversation_id: conversation.id)

    activity
  end

  # Every enveloped user turn a client receives until it is quiet for `quiet` ms:
  # `{turns, client}`, turns as `{conversation_id, text}` in arrival order.
  defp drain(client, quiet \\ 300, acc \\ []) do
    case Client.recv(client, quiet) do
      {:timeout, client} ->
        {Enum.reverse(acc), client}

      {%{"conversationId" => id, "frame" => %{"type" => "text", "from" => "user"} = frame},
       client} ->
        drain(client, quiet, [{id, frame["data"]["text"]} | acc])

      {%{}, client} ->
        drain(client, quiet, acc)

      {other, _client} ->
        flunk("unexpected #{inspect(other)}")
    end
  end

  # Exactly `n` user turns, however slowly they arrive (a loaded CI runner),
  # then `quiet` ms without another one.
  defp take(client, n, quiet \\ 300, acc \\ [])

  defp take(client, 0, quiet, acc) do
    {rest, client} = drain(client, quiet)
    {Enum.reverse(acc) ++ rest, client}
  end

  defp take(client, n, quiet, acc) do
    case Client.recv(client, 5_000) do
      {%{"conversationId" => id, "frame" => %{"type" => "text", "from" => "user"} = frame},
       client} ->
        take(client, n - 1, quiet, [{id, frame["data"]["text"]} | acc])

      {%{}, client} ->
        take(client, n, quiet, acc)

      {other, _client} ->
        flunk("expected #{n} more turns, got #{inspect(other)}")
    end
  end

  # The settle delay of members that join from now on (restored after the test).
  defp settle(ms) do
    previous = Application.get_env(:converger, ConvergerWeb.Protocol, [])
    on_exit(fn -> Application.put_env(:converger, ConvergerWeb.Protocol, previous) end)

    Application.put_env(
      :converger,
      ConvergerWeb.Protocol,
      Keyword.put(previous, :group_settle_ms, ms)
    )
  end

  # The next enveloped ack (other frames dropped).
  defp recv_ack(client) do
    case Client.recv(client, 2_000) do
      {%{"frame" => %{"type" => "ack"}} = envelope, client} -> {envelope, client}
      {%{}, client} -> recv_ack(client)
      {other, _client} -> flunk("expected an ack, got #{inspect(other)}")
    end
  end

  defp served_by(turns), do: turns |> Enum.map(&elem(&1, 0)) |> MapSet.new()

  describe "affinity" do
    test "every turn of a conversation goes to the same member; conversations spread", ctx do
      a = agent(ctx, "agent-a")
      b = agent(ctx, "agent-b")
      Process.sleep(@settle)

      for round <- 1..3, conversation <- ctx.conversations do
        turn(ctx, conversation, "turn #{round}")
      end

      {turns_a, _a} = drain(a)
      {turns_b, _b} = drain(b)

      # Each of the 36 turns was delivered exactly once.
      expected = for round <- 1..3, c <- ctx.conversations, do: {c.id, "turn #{round}"}
      assert Enum.sort(turns_a ++ turns_b) == Enum.sort(expected)

      # A conversation is served by one member only, in order.
      assert MapSet.disjoint?(served_by(turns_a), served_by(turns_b))

      for {id, _} <- turns_a ++ turns_b do
        texts = for {^id, text} <- turns_a ++ turns_b, do: text
        assert texts == ["turn 1", "turn 2", "turn 3"]
      end

      # Both members serve some (12 conversations: all on one member is 1 in 2048).
      assert MapSet.size(served_by(turns_a)) > 0
      assert MapSet.size(served_by(turns_b)) > 0
    end
  end

  describe "takeover" do
    test "a member leaves without answering: its turn goes to the remaining member once", ctx do
      a = agent(ctx, "agent-a")
      b = agent(ctx, "agent-b")
      Process.sleep(@settle)

      for conversation <- ctx.conversations, do: turn(ctx, conversation, "first")
      {turns_a, a} = drain(a)
      {turns_b, b} = drain(b)
      served_a = served_by(turns_a)
      assert MapSet.size(served_a) > 0

      # A disconnects without answering: B takes A's conversations over and
      # gets their unanswered turns, exactly once.
      Client.close(a)
      {taken_over, b} = drain(b)
      assert Enum.sort(taken_over) == Enum.sort(for id <- served_a, do: {id, "first"})

      # The next turn of every conversation goes to B, exactly once.
      for conversation <- ctx.conversations, do: turn(ctx, conversation, "second")
      {turns, _b} = drain(b)
      assert Enum.sort(turns) == Enum.sort(for c <- ctx.conversations, do: {c.id, "second"})

      # B's own conversations were never delivered twice.
      assert Enum.all?(turns_b, &(elem(&1, 1) == "first"))
    end

    test "a turn the leaving member answered is not delivered again", ctx do
      a = agent(ctx, "agent-a")
      b = agent(ctx, "agent-b")
      Process.sleep(@settle)

      for conversation <- ctx.conversations, do: turn(ctx, conversation, "first")
      {turns_a, a} = drain(a)
      {_turns_b, b} = drain(b)
      assert turns_a != []

      # A answers each of its turns, then leaves.
      a =
        Enum.reduce(turns_a, a, fn {id, _text}, a ->
          reply = %{"type" => "text", "clientId" => "r-#{id}", "data" => %{"text" => "answer"}}
          a = Client.push(a, %{"conversationId" => id, "frame" => reply})
          {%{"frame" => %{"type" => "ack"}}, a} = recv_ack(a)
          a
        end)

      Client.close(a)
      {taken_over, b} = drain(b)
      assert taken_over == []

      [{id, _} | _] = turns_a
      turn(ctx, %{id: id}, "second")
      assert {[{^id, "second"}], _b} = drain(b)
    end

    test "a turn passed to a member that is gone but still listed is taken over (the gap)",
         ctx do
      b = agent(ctx, "agent-b")
      Process.sleep(@settle)

      # A member that never delivers anything: like a connection that died and
      # whose `:pg` membership has not been removed yet.
      ghost = start_ghost(ctx.bot.id)
      Process.sleep(50)
      conversation = Enum.find(ctx.conversations, &ghost_owns?(ghost, &1.id))
      assert conversation, "the ghost owns none of the conversations"

      turn(ctx, conversation, "while the owner is gone")
      {[], b} = drain(b)

      # The membership is cleaned up: B, the new owner, gets the turn once.
      Process.exit(ghost, :kill)
      {taken_over, b} = drain(b)
      assert taken_over == [{conversation.id, "while the owner is gone"}]

      turn(ctx, conversation, "next")
      assert {[{_, "next"}], _b} = drain(b)
    end
  end

  describe "join" do
    test "a new member moves only some conversations and never takes a turn being answered",
         ctx do
      a = agent(ctx, "agent-a")
      Process.sleep(@settle)

      for conversation <- ctx.conversations, do: turn(ctx, conversation, "first")
      {turns_a, a} = drain(a)
      assert length(turns_a) == length(ctx.conversations)

      # B joins, with a settle delay long enough for the turns below. Turns
      # committed before it is eligible stay with A, and B never receives A's
      # earlier turns.
      settle(5_000)
      b = agent(ctx, "agent-b")
      # B joined the group before its welcome: eligible by now + settle at the latest.
      joined_at = System.monotonic_time(:millisecond)
      for conversation <- ctx.conversations, do: turn(ctx, conversation, "during settle")
      {during_a, a} = take(a, length(ctx.conversations))
      {during_b, b} = drain(b, 100)
      assert during_b == []
      assert length(during_a) == length(ctx.conversations)

      # Wait out the rest of B's settle delay, measured from its join.
      Process.sleep(max(joined_at + 5_200 - System.monotonic_time(:millisecond), 0))

      for conversation <- ctx.conversations, do: turn(ctx, conversation, "after")
      {after_a, a} = drain(a, 1_000)
      {after_b, _b} = drain(b, 1_000)

      moved = served_by(after_b)
      assert MapSet.size(moved) in 1..(length(ctx.conversations) - 1)

      assert Enum.sort(after_a ++ after_b) ==
               Enum.sort(for c <- ctx.conversations, do: {c.id, "after"})

      assert MapSet.disjoint?(served_by(after_a), moved)
      assert Enum.all?(after_b, &(elem(&1, 1) == "after"))

      # A's in-flight answer to a conversation that moved is still accepted.
      [id | _] = MapSet.to_list(moved)
      reply = %{"type" => "text", "clientId" => "late", "data" => %{"text" => "late answer"}}
      a = Client.push(a, %{"conversationId" => id, "frame" => reply})

      assert {%{"conversationId" => ^id, "frame" => %{"clientId" => "late"}}, _a} =
               recv_ack(a)
    end
  end

  describe "busy" do
    test "the bot owns the turn lock: its busy error reaches the end user", ctx do
      [conversation | _] = ctx.conversations
      a = agent(ctx, "agent-a")

      {:ok, token, _} =
        ConvergerToken.generate_conversation_token(ctx.widget, conversation.id, user_id: "alice")

      {:ok, user} = Client.connect(ctx.port, headers: [{"authorization", "Bearer #{token}"}])
      user = Client.push(user, %{"type" => "hello"})
      assert {%{"type" => "welcome"}, user} = Client.recv(user)

      # Two turns in a row: Converger delivers both (it does not serialise turns).
      for text <- ["one", "two"], do: turn(ctx, conversation, text)
      assert {[{_, "one"}, {_, "two"}], a} = drain(a)

      busy = %{
        "type" => "error",
        "data" => %{"code" => "busy", "message" => "still answering the previous turn"}
      }

      _a = Client.push(a, %{"conversationId" => conversation.id, "frame" => busy})
      {frame, _user} = Client.recv_type(user, "error")
      assert %{"data" => %{"code" => "busy"}} = frame
    end
  end

  defp start_ghost(channel_id) do
    test = self()

    spawn(fn ->
      membership = GroupMembership.join(channel_id, "workers", since: 0)
      send(test, :ghost_joined)
      ghost_loop(membership)
    end)
    |> tap(fn _ -> assert_receive :ghost_joined end)
  end

  defp ghost_loop(membership) do
    receive do
      {:owns?, id, from} ->
        send(from, {:owns, GroupMembership.serves?(membership, id, :now)})
        ghost_loop(membership)

      message ->
        membership =
          case GroupMembership.handle(membership, message) do
            {_event, _pids, membership} -> membership
            :ignore -> membership
          end

        ghost_loop(membership)
    end
  end

  defp ghost_owns?(ghost, id) do
    send(ghost, {:owns?, id, self()})
    assert_receive {:owns, owns?}
    owns?
  end
end
