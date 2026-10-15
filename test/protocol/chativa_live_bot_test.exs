defmodule Converger.ChativaLiveBotTest do
  @moduledoc """
  chativa's unmodified `@chativa/connector-mekik` against a live mekik bot
  behind Converger (#63, #65): the acceptance criteria "connects to
  Converger, resumes with a watermark and renders text, tool_call, genui,
  interrupt from a mekik bot behind Converger" and "the chativa sandbox with
  connector mekik works end to end (text, typing via run, interrupt chips,
  GenUI)".

  The end user is chativa's real `MekikConnector` (Node, see
  `Converger.ChativaHarness`) on a `websocket` widget channel, connected the
  way docs/protocol/clients.md describes. A routing rule sends the
  conversation to the bot, which plays the scripted mekik refund turn of
  `Converger.FakeMekikServer` (`run`, `tool_call` running and completed, a
  GenUI chunk, a `text`, an approval `interrupt`):

    * **Mode A**: a `mekik` channel; the adapter dials the fake mekik/1
      server (`Converger.Channels.Adapters.Mekik`, ADR-0066).
    * **Mode B**: an agent on a channel-scoped socket of a `websocket` bot
      channel (ADR-0063), played by this test with
      `ConvergerWeb.ProtocolClient`, sending the same frames.

  The user taps the interrupt's chip (chativa turns it into its `resume`
  frame), the bot answers with `interrupt_resolved` and a final text; then
  chativa disconnects, the bot sends two frames it misses, and chativa
  reconnects with its watermark and renders exactly those, once.

  Same skip rules as `Converger.ChativaCompatTest`: needs Node >= 22.18,
  skipped without it unless `CHATIVA_COMPAT=required` (CI).
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ChativaHarness, only: [command: 2, await: 2, drain: 2, shown: 1]

  alias Converger.{Activities, ChativaHarness, FakeMekikServer, RoutingRules}
  alias Converger.Auth.ConvergerToken
  alias Converger.Channels.Mekik.{Connections, Relay}
  alias ConvergerWeb.ProtocolClient, as: Client

  @moduletag :protocol
  @moduletag :chativa

  cond do
    node = ChativaHarness.node_executable() ->
      @node node

    System.get_env("CHATIVA_COMPAT") == "required" ->
      raise "CHATIVA_COMPAT=required but no node with TypeScript type stripping (>= 22.18) is on PATH"

    true ->
      @node nil
      @moduletag skip:
                   "chativa compatibility needs node >= 22.18 (TypeScript type stripping) on PATH"
  end

  # What the bot sends while chativa is away.
  @missed [
    %{
      "type" => "text",
      "id" => "msg-missed",
      "from" => "bot",
      "data" => %{"text" => "Your refund is on its way."}
    },
    %{
      "type" => "genui",
      "streamId" => "refund-ORD-42",
      "chunk" => %{
        "type" => "ui",
        "component" => "refund-status",
        "props" => %{"status" => "issued"},
        "id" => 1
      },
      "done" => true
    }
  ]

  setup do
    tenant = tenant_fixture()
    widget = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, widget)
    port = Client.start_server()
    %{tenant: tenant, widget: widget, conversation: conversation, port: port}
  end

  ## The two bots

  # Mode A: a `mekik` channel served by the fake mekik/1 server.
  defp mode_a(ctx) do
    webhook = Application.get_env(:converger, :webhook, [])
    Application.put_env(:converger, :webhook, Keyword.put(webhook, :allow_private_targets, true))
    on_exit(fn -> Application.put_env(:converger, :webhook, webhook) end)

    {:ok, fake} = FakeMekikServer.start_link(self(), genui: true)
    on_exit(fn -> FakeMekikServer.stop(fake) end)

    mekik = channel_fixture(ctx.tenant, type: "mekik", config: %{"url" => fake.url})
    route!(ctx, mekik)
    :ok = Relay.watch(mekik.id)
    on_exit(fn -> Connections.stop_channel(mekik.id) end)

    %{mode: :a, fake: fake}
  end

  # Mode B: an agent on a channel-scoped socket of a `websocket` bot channel.
  defp mode_b(ctx) do
    bot = channel_fixture(ctx.tenant)
    route!(ctx, bot)

    {:ok, token, _} = ConvergerToken.generate_token(bot, scope: "channel", user_id: "mekik")
    {:ok, agent} = Client.connect(ctx.port, headers: [{"authorization", "Bearer #{token}"}])
    agent = Client.push(agent, %{"type" => "hello", "protocol" => "converger/1"})
    {%{"type" => "welcome", "data" => %{"scope" => "channel"}}, agent} = Client.recv(agent)

    %{mode: :b, agent: agent}
  end

  defp route!(ctx, target) do
    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "widget to bot",
        tenant_id: ctx.tenant.id,
        source_channel_id: ctx.widget.id,
        target_channel_ids: [target.id]
      })
  end

  # The bot receives the user's turn and plays the refund turn.
  defp bot_turn(%{mode: :a} = bot, _ctx) do
    assert {_socket, %{"data" => %{"text" => "ORD-42"}}} = upstream("text")
    bot
  end

  defp bot_turn(%{mode: :b, agent: agent} = bot, ctx) do
    {frame, agent} = recv_enveloped(agent, ctx, "text")
    assert %{"from" => "user", "data" => %{"text" => "ORD-42"}} = frame
    %{bot | agent: push_all(agent, ctx, FakeMekikServer.refund_turn(genui: true))}
  end

  # The bot receives chativa's resume and answers it.
  defp bot_resume(%{mode: :a} = bot, _ctx) do
    assert {_socket, resume} = upstream("resume")
    assert resume == %{"type" => "resume", "answers" => %{"int-1" => %{"approved" => true}}}
    bot
  end

  defp bot_resume(%{mode: :b, agent: agent} = bot, ctx) do
    {resume, agent} = recv_enveloped(agent, ctx, "resume")
    assert resume == %{"type" => "resume", "answers" => %{"int-1" => %{"approved" => true}}}
    %{bot | agent: push_all(agent, ctx, FakeMekikServer.refund_reply(%{"approved" => true}))}
  end

  # The bot sends frames on its own (no turn): the frames chativa misses.
  defp bot_send(%{mode: :a, fake: fake} = bot, frames, _ctx) do
    [mekik_conversation] = FakeMekikServer.conversations(fake)
    for frame <- frames, do: FakeMekikServer.emit(fake, mekik_conversation, frame)
    bot
  end

  defp bot_send(%{mode: :b, agent: agent} = bot, frames, ctx) do
    %{bot | agent: push_all(agent, ctx, frames)}
  end

  defp push_all(agent, ctx, frames) do
    Enum.reduce(frames, agent, fn frame, agent ->
      Client.push(agent, %{"conversationId" => ctx.conversation.id, "frame" => frame})
    end)
  end

  # The next frame of `type` the agent receives for this conversation.
  defp recv_enveloped(agent, ctx, type) do
    id = ctx.conversation.id

    case Client.recv(agent, 3_000) do
      {%{"conversationId" => ^id, "frame" => %{"type" => ^type} = frame}, agent} -> {frame, agent}
      {%{}, agent} -> recv_enveloped(agent, ctx, type)
      {other, _agent} -> flunk("expected an enveloped #{type}, got #{inspect(other)}")
    end
  end

  # The next client frame of `type` the fake mekik server received.
  defp upstream(type) do
    receive do
      {:mekik_frame, socket, %{"type" => ^type} = frame} -> {socket, frame}
      {:mekik_frame, _socket, _other} -> upstream(type)
    after
      3_000 -> flunk("mekik server received no #{type}")
    end
  end

  # A page reload while the bot is parked on the interrupt: chativa's
  # persisted watermark is past the interrupt, so only welcome.pending can
  # bring the chips back.
  defp reload_while_parked(ctx, bot) do
    storage =
      Path.join(System.tmp_dir!(), "chativa_storage_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(storage) end)
    page = %{storage: storage, resumeConversation: true}

    {port, _welcome, _} = start_chativa(ctx, page)
    {_sent, _} = send_text(port, "1750000000000-ord42", "ORD-42")
    bot = bot_turn(bot, ctx)

    {interrupt, _} =
      await(port, &match?(%{"event" => "message", "message" => %{"id" => "interrupt-" <> _}}, &1))

    # run interrupted is transient: the watermark is the interrupt's seq.
    [interrupt_activity] = Enum.filter(stored(ctx), &(&1.message_type == "interrupt"))
    _ = drain(port, 200)
    command(port, %{cmd: "exit"})
    assert_receive {^port, {:exit_status, 0}}, 3_000

    # chativa persisted its session (localStorage values are JSON strings).
    assert [%{"watermark" => watermark}] =
             storage
             |> File.read!()
             |> Jason.decode!()
             |> Map.values()
             |> Enum.map(&Jason.decode!/1)

    assert watermark == interrupt_activity.seq

    # The reloaded page: nothing is replayed, the open interrupt is
    # re-announced and rendered as the same chips.
    {port, welcome, _} = start_chativa(ctx, page)
    assert welcome["identity"]["watermark"] == watermark
    {chips, events} = await(port, &(&1["event"] == "message"))
    assert shown(events) == []
    assert chips["message"]["id"] == interrupt["message"]["id"]
    assert chips["message"]["data"] == interrupt["message"]["data"]

    # Tapping a chip answers it with chativa's resume frame.
    {_sent, _} = send_text(port, "1750000000001-approve", "Approve")
    _bot = bot_resume(bot, ctx)
    {reply, _} = await(port, &(&1["event"] == "message"))
    assert reply["message"]["data"]["text"] == "Refund complete: ORD-42"

    # Resolved: a later reload re-announces nothing.
    command(port, %{cmd: "exit"})
    assert_receive {^port, {:exit_status, 0}}, 3_000
    {port, _welcome, _} = start_chativa(ctx, page)
    assert shown(drain(port, 500)) == []
  end

  defp stored(ctx), do: Activities.list_activities_since(ctx.conversation.id, nil)

  defp eventually(fun, attempts \\ 60) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(50)
        eventually(fun, attempts - 1)
    end
  end

  ## chativa

  # chativa's MekikConnector, configured as docs/protocol/clients.md
  # describes: TokenAuth, the conversation id, routeInUrl, no subprotocol.
  defp start_chativa(ctx, options \\ %{}) do
    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(ctx.widget, ctx.conversation.id,
        user_id: "alice"
      )

    ChativaHarness.start(
      @node,
      Map.merge(
        %{
          url: "ws://127.0.0.1:#{ctx.port}/socket/converger/v1",
          token: token,
          conversationId: ctx.conversation.id,
          routeInUrl: true
        },
        options
      )
    )
  end

  # A turn the way ChatEngine sends it (createOutgoingMessage); a tapped chip
  # sends its label as the text.
  defp send_text(port, id, text) do
    command(port, %{cmd: "send", message: %{id: id, type: "text", data: %{text: text}}})
    await(port, &(&1 == %{"event" => "sent", "id" => id}))
  end

  defp typing(events), do: for(%{"event" => "typing", "isTyping" => on} <- events, do: on)

  defp index(events, fun), do: Enum.find_index(events, fun)

  ## The conversation

  defp refund_conversation(ctx, bot) do
    {port, welcome, _} = start_chativa(ctx)
    assert welcome["identity"]["conversationId"] == ctx.conversation.id
    assert welcome["identity"]["userId"] == "alice"

    # 1. The user's turn; the bot's live refund turn renders.
    {_sent, _} = send_text(port, "1750000000000-ord42", "ORD-42")
    bot = bot_turn(bot, ctx)

    {interrupt, events} =
      await(port, &match?(%{"event" => "message", "message" => %{"id" => "interrupt-" <> _}}, &1))

    # run started -> typing on, before the first trace.
    first_trace = index(events, &(&1["event"] == "toolCall"))
    assert index(events, &(&1 == %{"event" => "typing", "isTyping" => true})) < first_trace

    assert [
             %{
               "event" => "toolCall",
               "toolCall" => %{"id" => "tool-1", "name" => "get_order", "status" => "running"}
             },
             %{
               "event" => "toolCall",
               "toolCall" => %{
                 "id" => "tool-1",
                 "status" => "completed",
                 "result" => %{"total" => 249.9}
               }
             },
             %{
               "event" => "genui",
               "streamId" => "order-ORD-42",
               "done" => true,
               "chunk" => %{
                 "type" => "ui",
                 "component" => "order-card",
                 "props" => %{"id" => "ORD-42", "total" => 249.9},
                 "id" => 1
               }
             },
             %{
               "event" => "message",
               "message" => %{
                 "id" => "msg-order",
                 "type" => "text",
                 "from" => "bot",
                 "data" => %{"text" => "ORD-42 was delivered damaged."}
               }
             }
           ] = shown(events)

    # The interrupt: quick-reply chips from its actions (labels only; the
    # connector maps a tapped label back to the action's value).
    assert %{
             "id" => "interrupt-int-1",
             "type" => "quick-reply",
             "data" => %{
               "text" => "Refund $249.9 for ORD-42?",
               "actions" => [
                 %{"label" => "Approve", "value" => "Approve"},
                 %{"label" => "Reject", "value" => "Reject"}
               ]
             }
           } = interrupt["message"]

    # run interrupted -> typing off; nothing else is rendered.
    rest = drain(port, 300)
    assert List.last(typing(events ++ [interrupt] ++ rest)) == false
    assert shown(rest) == []

    # 2. The user taps "Approve": chativa sends its resume frame; the bot
    # resolves the interrupt and answers.
    {_sent, _} = send_text(port, "1750000000001-approve", "Approve")
    bot = bot_resume(bot, ctx)

    {reply, events} = await(port, &(&1["event"] == "message"))

    assert %{
             "id" => "msg-reply",
             "type" => "text",
             "from" => "bot",
             "data" => %{"text" => "Refund complete: ORD-42"}
           } = reply["message"]

    # interrupt_resolved renders nothing; run started/finished toggle typing.
    assert shown(events) == []
    assert true in typing(events)
    rest = drain(port, 300)
    assert shown(rest) == []
    assert List.last(typing(events ++ rest)) == false

    # chativa's watermark is the reply's seq, the head of the transcript.
    seen = reply["message"]["seq"]
    assert List.last(stored(ctx)).seq == seen

    # 3. chativa goes away; the bot sends two frames it misses.
    command(port, %{cmd: "disconnect"})
    {_closed, _} = await(port, &(&1["event"] == "closed"))
    bot = bot_send(bot, @missed, ctx)
    eventually(fn -> List.last(stored(ctx)).seq == seen + 2 end)

    # 4. It reconnects with its watermark and renders exactly the missed
    # frames, once.
    command(port, %{cmd: "connect"})
    {connecting, _} = await(port, &(&1["event"] == "connecting"))
    assert connecting["watermark"] == seen

    {welcome, _} = await(port, &ChativaHarness.welcome?/1)
    assert welcome["identity"]["watermark"] == seen + 2

    events = drain(port, 800)

    assert [
             %{
               "event" => "message",
               "message" => %{
                 "id" => "msg-missed",
                 "seq" => missed_seq,
                 "from" => "bot",
                 "data" => %{"text" => "Your refund is on its way."}
               }
             },
             %{
               "event" => "genui",
               "streamId" => "refund-ORD-42",
               "done" => true,
               "chunk" => %{"component" => "refund-status"}
             }
           ] = shown(events)

    assert missed_seq == seen + 1
    refute Enum.any?(events, &(&1["event"] == "disconnected"))

    {port, bot}
  end

  ## Tests

  test "Mode A: chativa renders a mekik bot served by the mekik adapter, and resumes", ctx do
    bot = mode_a(ctx)
    {_port, _bot} = refund_conversation(ctx, bot)

    # Converger's transcript of the conversation.
    assert Enum.map(stored(ctx), &(&1.message_type || &1.text)) == [
             "ORD-42",
             "tool_call",
             "tool_call",
             "genui",
             "text",
             "interrupt",
             "interrupt_resolved",
             "text",
             "text",
             "genui"
           ]
  end

  test "Mode A: a reloaded chativa page re-renders the open interrupt from welcome.pending",
       ctx do
    reload_while_parked(ctx, mode_a(ctx))
  end

  test "Mode B: a reloaded chativa page re-renders the open interrupt from welcome.pending",
       ctx do
    reload_while_parked(ctx, mode_b(ctx))
  end

  test "Mode B: chativa renders a mekik bot on a channel-scoped agent socket, and resumes",
       ctx do
    bot = mode_b(ctx)
    {_port, _bot} = refund_conversation(ctx, bot)

    assert Enum.map(stored(ctx), &(&1.message_type || &1.text)) == [
             "ORD-42",
             "tool_call",
             "tool_call",
             "genui",
             "text",
             "interrupt",
             "interrupt_resolved",
             "text",
             "text",
             "genui"
           ]
  end
end
