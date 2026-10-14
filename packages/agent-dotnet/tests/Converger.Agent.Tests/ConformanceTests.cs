using System.Text.Json;
using System.Text.Json.Nodes;
using Converger.Agent.Tests.Support;
using Xunit;

namespace Converger.Agent.Tests;

/// <summary>Runs every scenario of the shared agent fixture (packages/conformance/agent.json).</summary>
public class ConformanceTests
{
    private static readonly Lazy<JsonObject> Fixture =
        new(() => JsonNode.Parse(File.ReadAllText(Repo.AgentFixture))!.AsObject());

    public static IEnumerable<object[]> Scenarios() =>
        Fixture.Value["scenarios"]!.AsArray().Select(s => new object[] { s!["name"]!.GetValue<string>() });

    [Theory]
    [MemberData(nameof(Scenarios))]
    public async Task Scenario(string name)
    {
        var fixture = Fixture.Value;
        var scenario = fixture["scenarios"]!.AsArray().Single(s => s!["name"]!.GetValue<string>() == name)!.AsObject();
        var token = fixture["token"]!.GetValue<string>();
        var agentConfig = scenario["agent"] as JsonObject;

        await using var server = await FakeServer.StartAsync(token);
        var options = new AgentOptions
        {
            Url = server.Url,
            Token = token,
            Group = agentConfig?["group"]?.GetValue<string>(),
            BackoffInitial = TimeSpan.FromMilliseconds(10),
            BackoffMax = TimeSpan.FromMilliseconds(50),
        };
        if (agentConfig?["watermarks"] is JsonObject marks)
        {
            options.Watermarks = marks.ToDictionary(kv => kv.Key, kv => kv.Value!.GetValue<long>());
        }
        var agent = new ConvergerAgent(options);
        agent.OnTurn(FixtureHandler(fixture["handlers"]!.AsObject()));
        using var cts = new CancellationTokenSource();
        var run = agent.RunAsync(cts.Token);

        try
        {
            var caps = new Dictionary<string, string>(StringComparer.Ordinal);
            FakeConnection? conn = null;
            var steps = scenario["steps"]!.AsArray();
            for (var i = 0; i < steps.Count; i++)
            {
                var step = steps[i]!.AsObject();
                if (step.TryGetPropertyValue("expect", out var expect))
                {
                    conn ??= await server.AcceptAsync();
                    var got = await conn.NextAsync();
                    if (Matcher.Match(expect, got, caps, "frame") is { } error)
                    {
                        Assert.Fail($"step {i}: {error}\nagent sent: {got.ToJsonString()}");
                    }
                }
                else if (step.TryGetPropertyValue("send", out var send))
                {
                    Assert.NotNull(conn);
                    await conn.WriteAsync(Matcher.Subst(send, caps));
                }
                else if (step.TryGetPropertyValue("close", out var close))
                {
                    Assert.NotNull(conn);
                    await conn.CloseAsync(close!.GetValue<int>());
                    conn = null;
                }
            }
        }
        finally
        {
            cts.Cancel();
        }
        // RunAsync returns (no exception) after cancel.
        await run.WaitAsync(FakeServer.Timeout);
    }

    /// <summary>Runs the ops of handlers[turn.Text] (or handlers["*"]).</summary>
    internal static Func<Turn, Reply, CancellationToken, Task> FixtureHandler(JsonObject handlers) =>
        async (turn, reply, ct) =>
        {
            var ops = (handlers[turn.Text] ?? handlers["*"])!.AsArray();
            var answer = "";
            string Fill(string s) => s.Replace("{text}", turn.Text, StringComparison.Ordinal).Replace("{answer}", answer, StringComparison.Ordinal);
            foreach (var node in ops)
            {
                var op = node!.AsObject();
                switch (op["op"]!.GetValue<string>())
                {
                    case "text":
                        await reply.TextAsync(Fill(op["text"]!.GetValue<string>()), Actions(op["actions"]), ct);
                        break;
                    case "ask":
                        var a = await reply.AskAsync(op["payload"], Actions(op["actions"]), cancellationToken: ct);
                        answer = a.ValueKind == JsonValueKind.String ? a.GetString()! : a.GetRawText();
                        break;
                    case "typing":
                        await reply.TypingAsync(op["on"]!.GetValue<bool>(), ct);
                        break;
                    case "toolCall":
                        await reply.ToolCallAsync(
                            new ToolCall
                            {
                                Id = op["id"]!.GetValue<string>(),
                                Name = op["name"]!.GetValue<string>(),
                                Status = op["status"]!.GetValue<string>(),
                                Params = op["params"] as JsonObject,
                                Result = op["result"],
                            },
                            ct);
                        break;
                    case "message":
                        await reply.MessageAsync(op["type"]!.GetValue<string>(), op["data"]!, ct);
                        break;
                    default:
                        throw new InvalidOperationException("unknown op " + op["op"]);
                }
            }
        };

    private static List<AgentAction>? Actions(JsonNode? node) =>
        (node as JsonArray)?.Select(item => new AgentAction(item!["label"]!.GetValue<string>(), item["value"])).ToList();
}
