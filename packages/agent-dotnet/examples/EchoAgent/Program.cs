// An echo agent: answers every user turn of the channel with "You said: ..."; "refund" asks a question.
//
//   CONVERGER_URL=https://chat.example.com CONVERGER_TOKEN=<channel token> dotnet run --project examples/EchoAgent
using Converger.Agent;

var baseUrl = Environment.GetEnvironmentVariable("CONVERGER_URL") ?? "http://localhost:4000";
var token = Environment.GetEnvironmentVariable("CONVERGER_TOKEN")
    ?? throw new InvalidOperationException("set CONVERGER_TOKEN to a channel-scoped token");

var agent = new ConvergerAgent(new AgentOptions
{
    Url = ConvergerAgent.SocketUrl(baseUrl),
    Token = token,
    OnError = e => Console.Error.WriteLine(e),
});

agent.OnTurn(async (turn, reply, ct) =>
{
    if (turn.Text == "refund")
    {
        var answer = await reply.AskAsync(
            new { title = "Refund 249.90 TRY?" },
            [new AgentAction("Yes", "yes"), new AgentAction("No", "no")],
            cancellationToken: ct);
        await reply.TextAsync($"You answered {answer}.", cancellationToken: ct);
        return;
    }
    await reply.TypingAsync(true, ct);
    await reply.TextAsync($"You said: {turn.Text}", [new AgentAction("Refund", "refund")], ct);
});

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    cts.Cancel();
};

Console.WriteLine($"echo agent on {ConvergerAgent.SocketUrl(baseUrl)}, Ctrl+C to stop");
await agent.RunAsync(cts.Token);
