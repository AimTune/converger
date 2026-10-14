defmodule Converger.ChativaHarness do
  @moduledoc """
  Drives chativa's real `MekikConnector` through
  `test/protocol/fixtures/chativa/harness.mjs` (see its header comment and the
  fixtures README) for the chativa compatibility suites (#63, #65, ADR-0065).

  The harness prints every connector handler call as one JSON line; these
  helpers start it on a port, send it commands and wait for its events.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  @fixtures Path.expand("../protocol/fixtures/chativa", __DIR__)
  @harness Path.join(@fixtures, "harness.mjs")

  @doc "The vendored chativa sources and the harness."
  def fixtures, do: @fixtures

  @doc "The harness script."
  def harness, do: @harness

  @doc """
  The `node` executable when it runs TypeScript by type stripping (Node >=
  22.18, `process.features.typescript` is "strip" or "transform"), else nil.
  """
  def node_executable do
    node = System.find_executable("node")

    typescript? =
      node != nil and
        case System.cmd(node, ["-p", "process.features.typescript"], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out) in ["strip", "transform"]
          _ -> false
        end

    if typescript?, do: node
  end

  @doc """
  Starts a `MekikConnector` with `options` (`url`, `token`, `conversationId`,
  `routeInUrl`, ...) and waits for its first `welcome` (the `capabilities`
  event carrying the identity): `{port, welcome_event, events_before}`.
  """
  def start(node, options) do
    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        args: [@harness, "connect", Jason.encode!(options)],
        cd: @fixtures
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    {welcome, events} = await(port, &welcome?/1)
    {port, welcome, events}
  end

  @doc "Whether a harness event is the `capabilities` event a `welcome` triggers."
  def welcome?(event), do: match?(%{"event" => "capabilities", "identity" => %{}}, event)

  @doc "Sends a command (`send`, `disconnect`, `connect`, `exit`) to the harness."
  def command(port, command), do: Port.command(port, Jason.encode!(command) <> "\n")

  @doc "Receives harness events until one matches `fun`: `{event, events_before}`."
  def await(port, fun, timeout \\ 5_000), do: await(port, fun, [], timeout)

  defp await(port, fun, seen, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        event = Jason.decode!(line)
        if event["event"] == "error", do: flunk("chativa harness failed: #{event["message"]}")

        if fun.(event),
          do: {event, Enum.reverse(seen)},
          else: await(port, fun, [event | seen], timeout)

      {^port, {:exit_status, status}} ->
        flunk("chativa harness exited (#{status}) after #{inspect(Enum.reverse(seen))}")
    after
      timeout -> flunk("no matching chativa event, got #{inspect(Enum.reverse(seen))}")
    end
  end

  @doc "Every event that arrives within `ms`."
  def drain(port, ms), do: drain(port, ms, [])

  defp drain(port, ms, seen) do
    receive do
      {^port, {:data, {:eol, line}}} -> drain(port, ms, [Jason.decode!(line) | seen])
    after
      ms -> Enum.reverse(seen)
    end
  end

  @doc """
  What ChatEngine shows: every event but the typing toggles connector-mekik
  emits around each bot frame, the welcome's capabilities and the harness's
  own bookkeeping.
  """
  def shown(events) do
    Enum.reject(
      events,
      &(&1["event"] in ["typing", "capabilities", "sent", "connected", "closed", "connecting"])
    )
  end
end
