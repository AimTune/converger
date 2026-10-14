defmodule Converger.Acceptance.LangchainFaqLiveTest do
  @moduledoc """
  Live acceptance test of #67 (first criterion) with the REAL Python example
  `examples/agents/langchain-faq/` (LangGraph + `converger-agent`), run in
  Docker against this endpoint:

      mix test --only langchain_faq

  Excluded by default (tag `:langchain_faq`): it needs Docker. The example
  runs in `python:3.12-slim` (`LANGCHAIN_FAQ_IMAGE`) with its fake model
  (`FAQ_AGENT_FAKE_MODEL=1`: deterministic, no API key); its dependencies are
  installed once into the Docker volume `converger-langchain-faq-venv`
  (`LANGCHAIN_FAQ_VENV`), reused by later runs. The endpoint listens on every
  interface on a random port and the container reaches it through
  `host.docker.internal`.

  One tenant, three channels and two routing rules, as the example's README
  sets them up: a `websocket` widget channel and a `whatsapp_meta` channel,
  both routed to the `websocket` bot channel the agent serves (one socket,
  channel-scoped token minted from the bot channel's secret). The WhatsApp
  edge is the public one: signed Meta webhooks posted to
  `/api/v1/channels/:id/inbound`, the Graph API answered by a `Req.Test`
  stub. The widget user is a native Protocol v1 socket
  (`ConvergerWeb.ProtocolClient`, every server frame validated against the
  v1 schemas). The scenario, on each channel:

    1. the user asks "When does my order ship?": the widget gets the
       `search_faq` tool trace and the answer streamed as several `genui` text
       chunks of one `streamId`, then `done`; WhatsApp gets the joined answer
       as ONE text message (ADR-0064) and no tool trace;
    2. the user asks for a human: the graph pauses on its LangGraph
       `interrupt()`; the widget gets an `interrupt` with the two actions
       (chips), WhatsApp gets interactive reply buttons;
    3. the user answers (the widget's `resume` frame, the WhatsApp
       `button_reply` tap): the graph resumes and its final reply reaches the
       channel the user wrote from.
  """

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Channels, Repo, RoutingRules}
  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias Converger.Channels.{InboundSignature, RichContent}
  alias ConvergerWeb.ProtocolClient, as: Client

  @moduletag :langchain_faq
  @moduletag timeout: 600_000

  @wa_secret "meta-app-secret-faq"
  @wa_phone_number_id "106540352242922"
  @wa_phone "16505551234"

  @example "examples/agents/langchain-faq"
  @group "faq"

  # The example's fake model (faq_agent.fake_model/0) answers every question so.
  @answer "Orders ship within 1 business day and arrive in 2-4 business days."
  @title "Shall I connect you with a human agent?"
  @actions [
    %{"label" => "Yes, connect me", "value" => "yes"},
    %{"label" => "No, thanks", "value" => "no"}
  ]
  @connected "Done: a human agent will join this conversation shortly."
  @declined "No problem. Ask me anything about shipping, returns, refunds or payment."

  setup_all do
    docker = System.find_executable("docker") || raise "needs docker on PATH"
    image = System.get_env("LANGCHAIN_FAQ_IMAGE", "python:3.12-slim")
    venv = System.get_env("LANGCHAIN_FAQ_VENV", "converger-langchain-faq-venv")

    # The example's requirements (the SDK from this repository, editable) in
    # a reusable volume: a no-op after the first run.
    {out, status} =
      System.cmd(
        docker,
        ["run", "--rm"] ++
          mounts(venv) ++
          [
            image,
            "sh",
            "-c",
            "test -x /venv/bin/python || python -m venv /venv; " <>
              "/venv/bin/pip install -q --disable-pip-version-check -r requirements.txt"
          ],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("installing the example's requirements failed:\n#{out}")

    %{docker: docker, image: image, venv: venv}
  end

  defp mounts(venv) do
    ["-v", "#{File.cwd!()}:/w", "-v", "#{venv}:/venv", "-w", "/w/#{@example}"]
  end

  setup context do
    Req.Test.set_req_test_to_shared(context)
    test_pid = self()

    whatsapp_env = Application.get_env(:converger, :whatsapp_req_options)

    Application.put_env(:converger, :whatsapp_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn ->
      if whatsapp_env,
        do: Application.put_env(:converger, :whatsapp_req_options, whatsapp_env),
        else: Application.delete_env(:converger, :whatsapp_req_options)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      wamid = "wamid.out-#{System.unique_integer([:positive])}"
      send(test_pid, {:graph_api, conn.request_path, Jason.decode!(body), wamid})
      Req.Test.json(conn, %{"messages" => [%{"id" => wamid}]})
    end)

    tenant = tenant_fixture()
    bot = channel_fixture(tenant)
    widget = channel_fixture(tenant)

    {:ok, whatsapp} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "whatsapp_meta",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "phone_number_id" => @wa_phone_number_id,
          "access_token" => "token",
          "verify_token" => "verify",
          "app_secret" => @wa_secret
        }
      })

    for source <- [widget, whatsapp] do
      {:ok, _rule} =
        RoutingRules.create_routing_rule(%{
          name: "#{source.type} to faq bot",
          tenant_id: tenant.id,
          source_channel_id: source.id,
          target_channel_ids: [bot.id]
        })
    end

    port = Client.start_server(ip: :any)
    agent = start_agent(context, port, bot)

    %{tenant: tenant, bot: bot, widget: widget, whatsapp: whatsapp, port: port, agent: agent}
  end

  ## The agent: `python faq_agent.py` in Docker

  defp start_agent(ctx, port, bot) do
    name = "converger-langchain-faq-#{System.unique_integer([:positive])}"

    args =
      ["run", "--rm", "--name", name, "--add-host", "host.docker.internal:host-gateway"] ++
        mounts(ctx.venv) ++
        Enum.flat_map(
          [
            {"CONVERGER_URL", "http://host.docker.internal:#{port}"},
            {"CONVERGER_CHANNEL_SECRET", bot.secret},
            {"CONVERGER_AGENT_GROUP", @group},
            {"FAQ_AGENT_FAKE_MODEL", "1"},
            {"PYTHONUNBUFFERED", "1"}
          ],
          fn {key, value} -> ["-e", "#{key}=#{value}"] end
        ) ++ [ctx.image, "/venv/bin/python", "faq_agent.py"]

    agent =
      Port.open({:spawn_executable, ctx.docker}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 100_000},
        args: args
      ])

    docker = ctx.docker
    on_exit(fn -> System.cmd(docker, ["rm", "-f", name], stderr_to_stdout: true) end)

    # Connected: its socket joined the agent group of the bot channel.
    wait_for_agent(agent, bot.id, 600)
    agent
  end

  defp wait_for_agent(agent, bot_id, attempts) do
    cond do
      :pg.get_members(ConvergerWeb.Protocol.AgentGroups, {bot_id, @group}) != [] ->
        # Past the group's settle delay (100 ms in test), so it owns new turns.
        Process.sleep(200)

      attempts == 0 ->
        flunk("the agent never connected:\n#{Enum.join(agent_output(agent, 0), "\n")}")

      true ->
        receive do
          {^agent, {:exit_status, status}} ->
            flunk("the agent exited (#{status}):\n#{Enum.join(agent_output(agent, 0), "\n")}")
        after
          100 -> wait_for_agent(agent, bot_id, attempts - 1)
        end
    end
  end

  # What the agent process printed so far (its log lines).
  defp agent_output(agent, ms) do
    receive do
      {^agent, {:data, {_, line}}} -> [line | agent_output(agent, ms)]
    after
      ms -> []
    end
  end

  ## The web widget: a native socket

  defp widget_user(ctx) do
    conversation = conversation_fixture(ctx.tenant, ctx.widget)

    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(ctx.widget, conversation.id, user_id: "alice")

    {:ok, user} = Client.connect(ctx.port, headers: [{"authorization", "Bearer #{token}"}])
    user = Client.push(user, %{"type" => "hello"})
    {%{"type" => "welcome"}, user} = Client.recv(user)
    {conversation, user}
  end

  # Frames until (and including) the first one matching `done?`.
  defp widget_until(agent, user, done?, acc \\ []) do
    case Client.recv(user, 20_000) do
      {%{"type" => _} = frame, user} ->
        if done?.(frame),
          do: {Enum.reverse([frame | acc]), user},
          else: widget_until(agent, user, done?, [frame | acc])

      {other, _user} ->
        seen = acc |> Enum.reverse() |> Enum.map(&Map.take(&1, ["type", "data"]))

        flunk("""
        widget: #{inspect(other)} after #{inspect(seen)}
        agent output:
        #{Enum.join(agent_output(agent, 0), "\n")}
        """)
    end
  end

  defp run_finished?(frame),
    do: match?(%{"type" => "run", "data" => %{"status" => "finished"}}, frame)

  ## WhatsApp: signed Meta webhooks, the Graph API stub

  defp wa_inbound!(whatsapp, message) do
    params = %{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "id" => "1",
          "changes" => [
            %{
              "field" => "messages",
              "value" => %{
                "messaging_product" => "whatsapp",
                "metadata" => %{"phone_number_id" => @wa_phone_number_id},
                "contacts" => [%{"profile" => %{"name" => "Sheena"}, "wa_id" => @wa_phone}],
                "messages" => [
                  Map.merge(%{"from" => @wa_phone, "timestamp" => "1760140830"}, message)
                ]
              }
            }
          ]
        }
      ]
    }

    body = Jason.encode!(params)
    signature = "sha256=" <> InboundSignature.hmac_hex(@wa_secret, body)

    [id] =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(~p"/api/v1/channels/#{whatsapp.id}/inbound", body)
      |> json_response(200)
      |> Map.fetch!("activity_ids")

    Repo.get!(Activity, id)
  end

  # The next Graph API message send `{body, wamid}`; read receipts and
  # typing indicators (`status: read`) are skipped.
  defp graph_send do
    assert_receive {:graph_api, path, body, wamid}, 20_000
    assert path =~ "/#{@wa_phone_number_id}/messages"
    if body["status"] == "read", do: graph_send(), else: {body, wamid}
  end

  # Every further Graph API message send within `ms`.
  defp graph_sends(ms) do
    receive do
      {:graph_api, _path, %{"status" => "read"}, _wamid} -> graph_sends(ms)
      {:graph_api, _path, body, _wamid} -> [body | graph_sends(ms)]
    after
      ms -> []
    end
  end

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

  test "the LangChain FAQ example answers the widget and WhatsApp through one bot channel", ctx do
    # --- Web widget ------------------------------------------------------
    {conversation, user} = widget_user(ctx)

    # 1. A question: the tool trace and the answer streamed token by token.
    user =
      Client.push(user, %{
        "type" => "text",
        "clientId" => "w-1",
        "data" => %{"text" => "When does my order ship?"}
      })

    {frames, user} = widget_until(ctx.agent, user, &run_finished?/1)

    assert [
             %{"data" => %{"status" => "running", "name" => "search_faq"}},
             %{"data" => %{"status" => "completed", "name" => "search_faq"}}
           ] = Enum.filter(frames, &(&1["type"] == "tool_call"))

    genui = Enum.filter(frames, &(&1["type"] == "genui"))
    assert [%{"streamId" => stream_id} | _] = genui
    assert Enum.all?(genui, &(&1["streamId"] == stream_id))
    {chunks, [last]} = Enum.split(genui, -1)
    assert %{"done" => true, "chunk" => %{"type" => "event", "name" => "stream_done"}} = last
    assert length(chunks) > 1, "the answer is streamed in several chunks"
    assert Enum.all?(chunks, &(&1["done"] == false and &1["chunk"]["type"] == "text"))
    assert Enum.map_join(chunks, & &1["chunk"]["content"]) == @answer

    # One text run: the deltas share one chunk id (one growing bubble).
    assert [_run] = chunks |> Enum.map(& &1["chunk"]["id"]) |> Enum.uniq()

    # Streamed only: no duplicate `text` message of the answer.
    refute Enum.any?(frames, &(&1["type"] == "text" and &1["from"] == "bot"))

    # 2. A human, please: the LangGraph interrupt as chips.
    user =
      Client.push(user, %{
        "type" => "text",
        "clientId" => "w-2",
        "data" => %{"text" => "I want to talk to a human"}
      })

    {frames, user} = widget_until(ctx.agent, user, &(&1["type"] == "interrupt"))
    interrupt = List.last(frames)
    assert interrupt["data"]["payload"]["title"] == @title
    assert interrupt["data"]["actions"] == @actions
    assert Activities.interrupt_open?(conversation.id, interrupt["id"])

    # 3. The tapped chip: chativa's resume. The graph resumes and answers.
    user = Client.push(user, %{"type" => "resume", "answers" => %{interrupt["id"] => "yes"}})
    {frames, user} = widget_until(ctx.agent, user, &run_finished?/1)

    assert Enum.any?(
             frames,
             &(&1["type"] == "interrupt_resolved" and &1["id"] == interrupt["id"])
           )

    assert [%{"data" => %{"text" => @connected}}] =
             Enum.filter(frames, &(&1["type"] == "text" and &1["from"] == "bot"))

    Client.refute_frame(user, 500, ["deliveryStatus", "typing", "read"])
    refute Activities.interrupt_open?(conversation.id, interrupt["id"])

    # --- WhatsApp --------------------------------------------------------
    # 1. The same question: the joined answer as ONE text message; neither
    # the tool trace nor the chunks are sent.
    turn =
      wa_inbound!(ctx.whatsapp, %{
        "id" => "wamid.in-1",
        "type" => "text",
        "text" => %{"body" => "When does my order ship?"}
      })

    {answer, _wamid} = graph_send()

    assert %{"type" => "text", "to" => @wa_phone, "text" => %{"body" => @answer}} = answer
    assert graph_sends(1_000) == []

    # The same graph served it: the stream and the trace are in the transcript.
    stored = Activities.list_activities_since(turn.conversation_id, nil)
    assert Enum.count(stored, &(&1.message_type == "tool_call")) == 2
    assert Enum.count(stored, &(&1.message_type == "genui")) > 2

    # 2. A human, please: the interrupt as interactive reply buttons.
    wa_inbound!(ctx.whatsapp, %{
      "id" => "wamid.in-2",
      "type" => "text",
      "text" => %{"body" => "I want to talk to a human"}
    })

    {offer, offer_wamid} = graph_send()

    assert %{
             "to" => @wa_phone,
             "type" => "interactive",
             "interactive" => %{
               "type" => "button",
               "body" => %{"text" => body},
               "action" => %{"buttons" => buttons}
             }
           } = offer

    assert body =~ @title

    interrupt =
      turn.conversation_id
      |> Activities.list_activities_since(nil)
      |> Enum.filter(&(&1.message_type == "interrupt"))
      |> List.last()

    assert buttons ==
             for(
               {%{"label" => title}, index} <- Enum.with_index(@actions),
               do: %{
                 "type" => "reply",
                 "reply" => %{"id" => RichContent.ref(interrupt.id, index), "title" => title}
               }
             )

    assert Activities.interrupt_open?(turn.conversation_id, interrupt.payload["id"])

    # 3. The tap on "No, thanks" resumes the graph; the reply comes back.
    wa_inbound!(ctx.whatsapp, %{
      "id" => "wamid.in-3",
      "type" => "interactive",
      "context" => %{"from" => @wa_phone_number_id, "id" => offer_wamid},
      "interactive" => %{
        "type" => "button_reply",
        "button_reply" => %{"id" => RichContent.ref(interrupt.id, 1), "title" => "No, thanks"}
      }
    })

    {reply, _wamid} = graph_send()
    assert %{"type" => "text", "to" => @wa_phone, "text" => %{"body" => @declined}} = reply
    assert graph_sends(1_000) == []

    eventually(fn ->
      not Activities.interrupt_open?(turn.conversation_id, interrupt.payload["id"])
    end)

    # The agent logged no failure.
    output = agent_output(ctx.agent, 200)
    refute Enum.any?(output, &(&1 =~ ~r/Traceback|failed|ERROR/)), Enum.join(output, "\n")
  end
end
