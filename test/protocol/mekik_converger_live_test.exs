defmodule Converger.MekikConvergerLiveTest do
  @moduledoc """
  Live acceptance test of #64, Mode B, with REAL mekik and chativa code: the
  stock refund demo of the mekik repository served behind Converger by
  `@mekik/converger` (`node examples/refund.ts --converger`, AimTune/mekik#47),
  and chativa's unmodified `@chativa/connector-mekik` as the end user (the
  vendored copy driven by `Converger.ChativaHarness`).

      cd mekik/ts && pnpm install && pnpm build
      MEKIK_DIR=path/to/mekik mix test --only mekik_converger

  Excluded by default (tag `:mekik_converger`): it needs the mekik repository
  (`MEKIK_DIR`, default `../mekik`, with `ts/` built) and Node >= 22.18. The
  test starts the endpoint on a random port, creates a `websocket` widget
  channel routed to a `websocket` bot channel, and spawns the demo with
  `CONVERGER_URL` (the native socket) and `CONVERGER_SECRET` (the bot
  channel's secret: the transport mints its channel-scoped token with
  `POST /api/v1/converger/tokens/generate` on the same origin).

  The scenario, "mekik with `@mekik/converger` serves the same scenario with
  Converger as the only transcript; a reconnecting chativa client replays
  exactly once":

    1. chativa sends `ORD-42`; the real graph's greeting, `get_order` traces,
       `order-card` GenUI card and approval interrupt (chips) render;
    2. chativa taps Approve (its `resume` frame); the graph resumes and the
       final text renders;
    3. chativa disconnects; the same user, on another device, asks again, so
       the graph runs again while chativa is away;
    4. chativa reconnects with its watermark and receives exactly the frames
       it missed, each once; the open interrupt is also re-announced in
       `welcome.pending` under the same message id, which chativa's
       MessageStore renders once. A further reconnect replays nothing. The
       chips answer the open interrupt;
    5. Converger's transcript holds every bot frame once with a contiguous
       seq; mekik ran with the external-transcript profile, which keeps no
       history of its own (`connectConverger` refuses any other).
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ChativaHarness, only: [command: 2, await: 2, await: 3, drain: 2, shown: 1]

  alias Converger.{Activities, ChativaHarness, RoutingRules}
  alias Converger.Auth.ConvergerToken
  alias ConvergerWeb.ProtocolClient, as: Client

  @moduletag :mekik_converger

  setup do
    node = ChativaHarness.node_executable() || flunk("needs node >= 22.18 on PATH")
    mekik_ts = Path.expand("ts", System.get_env("MEKIK_DIR", "../mekik"))

    unless File.exists?(Path.join(mekik_ts, "packages/converger/dist/index.js")) do
      flunk("""
      no built @mekik/converger in #{mekik_ts}: set MEKIK_DIR to the mekik repository and
      run `cd $MEKIK_DIR/ts && pnpm install && pnpm build`
      """)
    end

    tenant = tenant_fixture()
    widget = channel_fixture(tenant)
    bot = channel_fixture(tenant)

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "widget to mekik",
        tenant_id: tenant.id,
        source_channel_id: widget.id,
        target_channel_ids: [bot.id]
      })

    conversation = conversation_fixture(tenant, widget)
    port = Client.start_server()
    mekik = start_mekik(node, mekik_ts, port, bot)

    %{
      node: node,
      tenant: tenant,
      widget: widget,
      bot: bot,
      conversation: conversation,
      port: port,
      mekik: mekik
    }
  end

  # `node examples/refund.ts --converger`, killed (with its process tree) on
  # exit; waits for the demo's "serving" line (the hub's first welcome).
  defp start_mekik(node, mekik_ts, port, bot) do
    mekik =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 100_000},
        args: ["examples/refund.ts", "--converger"],
        cd: mekik_ts,
        env: [
          {~c"CONVERGER_URL", ~c"ws://127.0.0.1:#{port}/socket/converger/v1"},
          {~c"CONVERGER_SECRET", String.to_charlist(bot.secret)},
          {~c"CONVERGER_TOKEN", false}
        ]
      ])

    {:os_pid, os_pid} = Port.info(mekik, :os_pid)
    on_exit(fn -> kill(os_pid) end)

    receive do
      {^mekik, {:data, {:eol, "mekik refund demo serving the Converger channel" <> _}}} -> mekik
    after
      15_000 -> flunk("mekik never connected: #{inspect(mekik_output(mekik, 0))}")
    end
  end

  defp kill(os_pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/PID", "#{os_pid}", "/T", "/F"], stderr_to_stdout: true)

      _ ->
        System.cmd("kill", ["#{os_pid}"], stderr_to_stdout: true)
    end
  end

  # What the mekik process printed (its transport errors, `onError`).
  defp mekik_output(mekik, ms) do
    receive do
      {^mekik, {:data, {_, line}}} -> [line | mekik_output(mekik, ms)]
    after
      ms -> []
    end
  end

  ## chativa

  # chativa's MekikConnector as docs/protocol/clients.md configures it.
  defp start_chativa(ctx) do
    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(ctx.widget, ctx.conversation.id,
        user_id: "alice"
      )

    ChativaHarness.start(ctx.node, %{
      url: "ws://127.0.0.1:#{ctx.port}/socket/converger/v1",
      token: token,
      conversationId: ctx.conversation.id,
      routeInUrl: true
    })
  end

  defp send_text(port, id, text) do
    command(port, %{cmd: "send", message: %{id: id, type: "text", data: %{text: text}}})
    await(port, &(&1 == %{"event" => "sent", "id" => id}))
  end

  defp chips?(event),
    do: match?(%{"event" => "message", "message" => %{"type" => "quick-reply"}}, event)

  defp reply?(text),
    do: &match?(%{"event" => "message", "message" => %{"data" => %{"text" => ^text}}}, &1)

  defp stored(ctx), do: Activities.list_activities_since(ctx.conversation.id, nil)

  defp eventually(fun, attempts \\ 200) do
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

  # A compact view of what chativa rendered.
  defp rendered(events) do
    events
    |> shown()
    |> Enum.map(fn
      %{"event" => "message", "message" => %{"type" => "quick-reply", "data" => data}} ->
        {:chips, data["text"], Enum.map(data["actions"], & &1["label"])}

      %{"event" => "message", "message" => %{"from" => from, "data" => %{"text" => text}}} ->
        {:message, from, text}

      %{"event" => "toolCall", "toolCall" => %{"name" => name, "status" => status}} ->
        {:tool_call, name, status}

      %{"event" => "genui", "chunk" => %{"type" => "ui", "component" => component}} ->
        {:genui, component}

      %{"event" => "genui", "chunk" => %{"type" => "text", "content" => content}} ->
        {:genui_text, content}

      %{"event" => "genui", "chunk" => %{"type" => "event", "name" => name}} ->
        {:genui_event, name}

      other ->
        other
    end)
  end

  @greeting "Hi! Send an order number to start a refund. Available orders: ORD-42."

  # The real graph's first turn, up to the approval.
  @lookup [
    {:tool_call, "get_order", "running"},
    {:tool_call, "get_order", "completed"},
    {:genui, "order-card"}
  ]
  @chips {:chips, "Refund $249.9 for ORD-42?", ["Approve", "Reject"]}

  # The resumed run, up to the consolidated reply.
  @refund [
    {:tool_call, "refund_payment", "running"},
    {:tool_call, "refund_payment", "completed"},
    {:genui_text, "Refund processed ✅"},
    {:genui_event, "stream_done"}
  ]

  test "the real refund graph behind Converger: chativa renders, approves, and replays exactly once",
       ctx do
    {port, welcome, _} = start_chativa(ctx)
    assert welcome["identity"]["conversationId"] == ctx.conversation.id
    assert welcome["identity"]["userId"] == "alice"

    # 1. The order number: the greeting, the lookup and the approval chips.
    {_sent, _} = send_text(port, "1760000000000-ord42", "ORD-42")
    {chips, events} = await(port, &chips?/1, 15_000)
    assert rendered(events) == [{:message, "bot", @greeting} | @lookup]
    assert rendered([chips]) == [@chips]

    # 2. The tap: chativa's resume; the graph resumes and answers.
    {_sent, _} = send_text(port, "1760000000001-approve", "Approve")
    {reply, events} = await(port, reply?("Refund complete: ORD-42"), 15_000)
    assert rendered(events) == @refund
    assert rendered(drain(port, 500)) == []

    seen = reply["message"]["seq"]
    assert List.last(stored(ctx)).seq == seen

    # 3. chativa goes away; the same user asks again on another device (a
    # fresh connector: it replays the history first), so the graph runs
    # again, up to the approval, while chativa is away.
    command(port, %{cmd: "disconnect"})
    {_closed, _} = await(port, &(&1["event"] == "closed"))

    {other, _welcome, _} = start_chativa(ctx)
    _history = drain(other, 500)
    {_sent, _} = send_text(other, "1760000000002-again", "ORD-42")
    eventually(fn -> Enum.count(stored(ctx), &(&1.message_type == "interrupt")) == 2 end)
    command(other, %{cmd: "exit"})

    head = List.last(stored(ctx)).seq
    assert head > seen

    # 4. chativa reconnects with its watermark and receives exactly what it
    # missed, once: the other device's turn, the lookup and the approval.
    # The open interrupt is also re-announced in welcome.pending (mekik/1
    # section 3.2, as a mekik server does), before the replay; both carry
    # the same message id, and chativa's MessageStore renders an id once.
    command(port, %{cmd: "connect"})
    {connecting, _} = await(port, &(&1["event"] == "connecting"))
    assert connecting["watermark"] == seen

    {welcome, _} = await(port, &ChativaHarness.welcome?/1)
    assert welcome["identity"]["watermark"] == head

    events = drain(port, 1_500)

    assert rendered(events) ==
             [@chips, {:message, "user", "ORD-42"} | @lookup] ++ [@chips]

    chip_ids = for %{"message" => %{"type" => "quick-reply", "id" => id}} <- events, do: id
    assert [id, id] = chip_ids

    assert rendered(Enum.uniq_by(shown(events), &(&1["message"]["id"] || make_ref()))) ==
             [@chips, {:message, "user", "ORD-42"} | @lookup]

    replayed_seqs = for %{"message" => %{"seq" => seq}} <- events, do: seq
    assert replayed_seqs == [seen + 1]

    # Its watermark is now the head: a further reconnect replays nothing
    # (only welcome.pending re-announces the open approval).
    command(port, %{cmd: "disconnect"})
    {_closed, _} = await(port, &(&1["event"] == "closed"))
    command(port, %{cmd: "connect"})
    {connecting, _} = await(port, &(&1["event"] == "connecting"))
    assert connecting["watermark"] == head
    {_welcome, _} = await(port, &ChativaHarness.welcome?/1)
    assert rendered(drain(port, 800)) == [@chips]

    # The chips answer the open interrupt.
    {_sent, _} = send_text(port, "1760000000003-approve", "Approve")
    {_reply, events} = await(port, reply?("Refund complete: ORD-42"), 15_000)
    assert rendered(events) == @refund
    assert rendered(drain(port, 500)) == []

    # 5. Converger is the only transcript: every bot frame is stored once,
    # in one contiguous seq space. chativa's resume is a bot-only frame (not
    # stored); interrupt_resolved records the answer.
    activities = stored(ctx)
    assert Enum.map(activities, & &1.seq) == Enum.to_list(1..length(activities))

    run = ["tool_call", "tool_call", "genui", "interrupt"]
    resumed = ["interrupt_resolved", "tool_call", "tool_call", "genui", "genui", "text"]

    assert Enum.map(activities, &(&1.message_type || &1.text)) ==
             ["ORD-42", "text"] ++ run ++ resumed ++ ["ORD-42"] ++ run ++ resumed

    # Each tool call is stored twice (running, completed), never more.
    tool_calls =
      for %{message_type: "tool_call", payload: %{"data" => %{"id" => id}}} <- activities,
          do: id

    assert tool_calls |> Enum.frequencies() |> Map.values() == [2, 2, 2, 2]
    assert Activities.open_interrupts(ctx.conversation.id) == []

    # mekik's transport reported no error (onError prints "converger: ...").
    assert mekik_output(ctx.mekik, 200) == []
  end
end
