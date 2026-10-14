defmodule ConvergerAgent.ConformanceTest do
  # One test per scenario of the shared agent fixture
  # (packages/conformance/agent.json), played against an in-process fake
  # server; every frame the agent sends is validated against the v1 schemas.
  use ExUnit.Case, async: true

  alias ConvergerAgent.{FakeServer, FixtureHandler, Wire}

  @moduletag :capture_log

  @fixture Wire.load_fixture()
  @external_resource Path.join(Wire.fixture_dir(), "agent.json")

  for scenario <- @fixture["scenarios"] do
    @scenario scenario
    test "conformance: #{scenario["name"]}" do
      run(@scenario)
    end
  end

  defp run(scenario) do
    fixture = @fixture
    token = fixture["token"]
    server = start_supervised!(FakeServer.child_spec(self()))
    agent_opts = scenario["agent"] || %{}

    agent =
      start_supervised!(
        {ConvergerAgent,
         url: FakeServer.url(server),
         token: token,
         handler: FixtureHandler.new(fixture["handlers"]),
         group: agent_opts["group"],
         watermarks: agent_opts["watermarks"] || %{},
         backoff_initial: 10,
         backoff_max: 50}
      )

    Enum.reduce(scenario["steps"], {nil, %{}}, fn step, {conn, caps} ->
      cond do
        Map.has_key?(step, "expect") ->
          conn = conn || Wire.accept(token)
          {conn, Wire.expect(conn, step["expect"], caps)}

        Map.has_key?(step, "send") ->
          Wire.write(conn, Wire.subst(step["send"], caps))
          {conn, caps}

        Map.has_key?(step, "close") ->
          Wire.close(conn, step["close"])
          {nil, caps}
      end
    end)

    assert :ok = ConvergerAgent.stop(agent, 5_000)
  end
end
