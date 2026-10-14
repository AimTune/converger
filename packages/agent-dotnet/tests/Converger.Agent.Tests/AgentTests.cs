using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Converger.Agent.Tests.Support;
using Xunit;

namespace Converger.Agent.Tests;

public class AgentTests
{
    private const string Conv = "c0a8012e-7d3b-4c5e-9f1a-2b3c4d5e6f70";

    private static JsonObject Welcome() => new()
    {
        ["type"] = "welcome",
        ["data"] = new JsonObject { ["protocol"] = "converger/1", ["scope"] = "channel", ["limits"] = new JsonObject() },
    };

    private static JsonObject UserTurn(long seq, string text, string conversationId = Conv) => new()
    {
        ["conversationId"] = conversationId,
        ["frame"] = new JsonObject
        {
            ["type"] = "text", ["id"] = "m", ["seq"] = seq, ["from"] = "user",
            ["data"] = new JsonObject { ["text"] = text },
        },
    };

    private static (ConvergerAgent Agent, Task Run, CancellationTokenSource Cts) Start(
        FakeServer server,
        Func<Turn, Reply, CancellationToken, Task> handler,
        Action<AgentOptions>? configure = null)
    {
        var options = new AgentOptions
        {
            Url = server.Url,
            Token = server.Token,
            BackoffInitial = TimeSpan.FromMilliseconds(5),
            BackoffMax = TimeSpan.FromMilliseconds(20),
        };
        configure?.Invoke(options);
        var agent = new ConvergerAgent(options);
        agent.OnTurn(handler);
        var cts = new CancellationTokenSource();
        return (agent, agent.RunAsync(cts.Token), cts);
    }

    private static Task Noop(Turn turn, Reply reply, CancellationToken ct) => Task.CompletedTask;

    private static void AssertMatch(JsonNode pattern, JsonNode actual)
    {
        if (Matcher.Match(pattern, actual, new Dictionary<string, string>(), "frame") is { } error)
        {
            Assert.Fail(error);
        }
    }

    [Fact]
    public void MatcherAndSchemaRejectMismatches()
    {
        var caps = new Dictionary<string, string>();
        Assert.NotNull(Matcher.Match(new JsonObject { ["type"] = "run" }, new JsonObject { ["type"] = "run", ["extra"] = 1 }, caps, "f"));
        Assert.NotNull(Matcher.Match(new JsonObject { ["id"] = "{{x}}" }, new JsonObject { ["id"] = "y" }, new Dictionary<string, string> { ["x"] = "z" }, "f"));
        Assert.NotNull(Matcher.Match(new JsonArray(1, 2), new JsonArray(1), caps, "f"));
        Assert.NotNull(Matcher.Match(new JsonObject { ["id"] = "$capture:c" }, new JsonObject { ["id"] = "" }, caps, "f"));
        Assert.Null(Matcher.Match(JsonNode.Parse("{\"n\":1}"), JsonNode.Parse("{\"n\":1.0}"), caps, "f"));
        var bad = new JsonObject
        {
            ["conversationId"] = Conv,
            ["frame"] = new JsonObject { ["type"] = "interrupt", ["data"] = new JsonObject() },
        };
        Assert.NotNull(Schemas.Check(Schemas.Envelope, bad));
        Assert.NotNull(Schemas.Check(Schemas.Hello, new JsonObject { ["type"] = "hello", ["group"] = "" }));
    }

    [Fact]
    public async Task ConnectsWithSubprotocolAndUserAgent()
    {
        await using var server = await FakeServer.StartAsync("tok");
        var (_, run, cts) = Start(server, Noop);
        var conn = await server.AcceptAsync();
        Assert.Contains(ConvergerAgent.Subprotocol, conn.RequestedSubprotocols);
        Assert.Equal("converger-agent-dotnet/" + ConvergerAgent.Version, conn.UserAgent);
        AssertMatch(new JsonObject { ["type"] = "hello", ["protocol"] = "converger/1" }, await conn.NextAsync());
        cts.Cancel();
        await run.WaitAsync(FakeServer.Timeout);
    }

    [Fact]
    public async Task UnauthorizedTwiceEndsRun()
    {
        await using var server = await FakeServer.StartAsync("tok");
        var calls = 0;
        var (_, run, cts) = Start(server, Noop, o =>
        {
            o.Token = null;
            o.TokenProvider = _ =>
            {
                Interlocked.Increment(ref calls);
                return ValueTask.FromResult("tok");
            };
        });
        using (cts)
        {
            for (var i = 0; i < 2; i++)
            {
                var conn = await server.AcceptAsync();
                await conn.NextAsync(); // hello
                await conn.WriteAsync(new JsonObject
                {
                    ["type"] = "error",
                    ["data"] = new JsonObject { ["code"] = "token_expired", ["message"] = "expired", ["retryable"] = true },
                });
                await conn.CloseAsync(4401);
            }
            var error = await Assert.ThrowsAsync<ConvergerCloseException>(() => run.WaitAsync(FakeServer.Timeout));
            Assert.Equal(4401, error.Code);
            Assert.Equal("token_expired", error.Last?.Code);
            Assert.Equal(2, Volatile.Read(ref calls));
        }
    }

    [Fact]
    public async Task ForbiddenEndsRun()
    {
        await using var server = await FakeServer.StartAsync("tok");
        var (_, run, cts) = Start(server, Noop);
        using (cts)
        {
            var conn = await server.AcceptAsync();
            await conn.NextAsync();
            await conn.CloseAsync(4403);
            var error = await Assert.ThrowsAsync<ConvergerCloseException>(() => run.WaitAsync(FakeServer.Timeout));
            Assert.Equal(4403, error.Code);
        }
    }

    [Fact]
    public async Task ThrowingHandlerEndsRunWithError()
    {
        await using var server = await FakeServer.StartAsync("tok");
        var reported = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
        var (_, run, cts) = Start(
            server,
            (_, _, _) => throw new InvalidOperationException("boom"),
            o => o.OnError = e => reported.TrySetResult(e));
        var conn = await server.AcceptAsync();
        await conn.NextAsync();
        await conn.WriteAsync(Welcome());
        await conn.WriteAsync(UserTurn(1, "hi"));
        foreach (var status in new[] { "started", "error" })
        {
            AssertMatch(
                new JsonObject
                {
                    ["conversationId"] = Conv,
                    ["frame"] = new JsonObject { ["type"] = "run", ["data"] = new JsonObject { ["status"] = status } },
                },
                await conn.NextAsync());
        }
        var error = await reported.Task.WaitAsync(FakeServer.Timeout);
        Assert.Equal("boom", error.Message);
        cts.Cancel();
        await run.WaitAsync(FakeServer.Timeout);
    }

    [Fact]
    public async Task ConversationsRunConcurrently()
    {
        await using var server = await FakeServer.StartAsync("tok");
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = new BlockingCollection<string>();
        var (_, run, cts) = Start(server, async (turn, _, _) =>
        {
            started.Add(turn.ConversationId);
            await release.Task;
        });
        var conn = await server.AcceptAsync();
        await conn.NextAsync();
        await conn.WriteAsync(Welcome());
        await conn.WriteAsync(UserTurn(1, "a"));
        await conn.WriteAsync(UserTurn(1, "b", "other"));
        var seen = new HashSet<string>();
        for (var i = 0; i < 2; i++)
        {
            Assert.True(started.TryTake(out var id, FakeServer.Timeout), $"only {string.Join(", ", seen)} started");
            seen.Add(id!);
        }
        Assert.Equal(new HashSet<string> { Conv, "other" }, seen);
        release.SetResult();
        cts.Cancel();
        await run.WaitAsync(FakeServer.Timeout);
    }

    [Fact]
    public async Task CancelStopsWaitingAsk()
    {
        await using var server = await FakeServer.StartAsync("tok");
        var askError = new TaskCompletionSource<Exception?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var (_, run, cts) = Start(server, async (_, reply, ct) =>
        {
            try
            {
                await reply.AskAsync(new JsonObject { ["title"] = "?" }, cancellationToken: ct);
                askError.TrySetResult(null);
            }
            catch (Exception e)
            {
                askError.TrySetResult(e);
                throw;
            }
        });
        var conn = await server.AcceptAsync();
        await conn.NextAsync();
        await conn.WriteAsync(Welcome());
        await conn.WriteAsync(UserTurn(1, "hi"));
        await conn.NextAsync(); // run started
        var interrupt = await conn.NextAsync();
        Assert.Equal("interrupt", interrupt["frame"]?["type"]?.GetValue<string>());
        cts.Cancel();
        await run.WaitAsync(FakeServer.Timeout); // returns, does not throw
        Assert.NotNull(await askError.Task.WaitAsync(FakeServer.Timeout));
    }
}
