---
title: Agent SDK for .NET (Converger.Agent)
description: Write a Converger agent in C# - one channel-scoped WebSocket serves every conversation of a channel, with turns, text and rich replies, tool-call traces, interrupts (AskAsync), reconnect and per-conversation watermarks.
sidebar_position: 8
---

# Agent SDK for .NET

**Implemented (#67)**, not yet published. `packages/agent-dotnet` is the `Converger.Agent` package (net8.0, no
dependencies beyond the BCL: `ClientWebSocket` and `System.Text.Json`). It has the same model and wire behaviour
as the [Go agent SDK](agent-go.md): one channel-scoped Protocol v1 connection
([section 10](../protocol/v1.md#10-channel-scoped-sockets-implemented-64-on-the-native-endpoint)) serves every
conversation routed to the agent's `websocket` channel.

## Install

```bash
dotnet add package Converger.Agent   # once published; until then reference packages/agent-dotnet/src/Converger.Agent
```

## Usage

The agent authenticates with a channel-scoped token of its `websocket` channel
(`POST /api/v1/converger/tokens/generate` with `{"scope": "channel"}`), sent as `Authorization: Bearer`.
`TokenProvider` is called on every connect, so an expired token is replaced.

```csharp
using Converger.Agent;

var agent = new ConvergerAgent(new AgentOptions
{
    Url = ConvergerAgent.SocketUrl("https://chat.example.com"),
    TokenProvider = async ct => await FetchChannelTokenAsync(ct), // or Token = "..."
    Group = "faq-bot",
    OnError = e => logger.LogWarning(e, "agent"),
});

agent.OnTurn(async (turn, reply, ct) =>
{
    if (turn.Text == "refund")
    {
        var answer = await reply.AskAsync(new { title = "Refund 249.90 TRY?" },
            [new AgentAction("Yes", "yes"), new AgentAction("No", "no")], cancellationToken: ct);
        await reply.TextAsync($"You answered {answer}.", cancellationToken: ct);
        return;
    }
    await reply.TypingAsync(true, ct);
    await reply.TextAsync($"You said: {turn.Text}", [new AgentAction("Talk to a human", "/human")], ct);
});

await agent.RunAsync(stoppingToken); // returns after cancellation; throws ConvergerCloseException when refused for good
```

| API | |
| --- | --- |
| `AgentOptions` | `Url`, `Token` or `TokenProvider`, `Group`, `UserId`, `Watermarks` (seed), `BackoffInitial` (500 ms), `BackoffMax` (30 s), `AckTimeout` (30 s), `Headers`, `OnError` |
| `agent.OnTurn((turn, reply, ct) => Task)`, `agent.RunAsync(ct)`, `agent.Watermarks` | handler, run loop, last seq seen per conversation |
| `Turn` | `ConversationId`, `Id`, `Seq`, `Text`, `Message` (`Type`, `Data`, `Raw`), `Participant`, `Meta`, `Metadata`, `Action`, `ReplyTo`, `Timestamp` |
| `reply.TextAsync(text, actions?, ct)`, `reply.MessageAsync(type, data, ct)` | message sends; wait for the `ack`, return `Ack` |
| `reply.AskAsync(payload, actions?, ui?, ct)` | `interrupt`, the user's answer, `interrupt_resolved`; returns the answer as `JsonElement` |
| `reply.ToolCallAsync(ToolCall, ct)`, `reply.TypingAsync(on, ct)`, `reply.SendAsync(JsonObject, ct)` | tool trace, typing, raw frame |
| `reply.End()` / `reply.EndAsync()` | `run {status: "finished"}` now (sent for you when the handler returns) |

Errors: a refused send throws `ConvergerException` (`Code`, `Message`, `Number`, `Retryable`, `RetryAfter`,
`ClientId`, `Details`, `ConversationId`); a missing ack throws `ConvergerAckTimeoutException`; calls after the
agent stopped throw `ConvergerStoppedException`; `RunAsync` throws `ConvergerCloseException` (`Code`, `Reason`,
`Last`) on 1008, 4400, 4403 or a second consecutive 4401.

## Behaviour

Identical to the [Go SDK](agent-go.md#behaviour): runs framed by `run started` / `finished` / `error`, turns
of one conversation serialised (an `AskAsync` answer is never queued), acked message sends re-sent with their
`clientId` after a reconnect, jittered backoff honouring `retryAfterMs`, `hello.watermarks` resume with
duplicates dropped, agent groups, and frames from the bot side never treated as turns. Interrupt ids are
`ask/<random>#<n>`.

## Tests and conformance

```bash
cd packages/agent-dotnet && dotnet build -warnaserror && dotnet test
```

The xUnit suite runs every scenario of `packages/conformance/agent.json` against an in-process Kestrel fake
server and validates every agent frame against the Protocol v1 schemas with `JsonSchema.Net`.
`examples/EchoAgent` (`CONVERGER_URL`, `CONVERGER_TOKEN`) was also run against a local server: a widget user's
turn and an `AskAsync` answered with `resume` round-tripped.

## Releases

`.github/workflows/agent-dotnet-publish.yml` publishes `Converger.Agent` to nuget.org
([#188](https://github.com/AimTune/converger/issues/188)). It runs only by hand (`workflow_dispatch`) and is a dry
run by default:

1. The `version` input must equal `<Version>` in `src/Converger.Agent/Converger.Agent.csproj`.
2. It builds with warnings as errors, runs the tests, packs in Release and uploads the `.nupkg` as an artifact.
3. With `dry_run` unchecked it pushes the package with the `NUGET_API_KEY` secret of the `nuget` environment: a
   nuget.org API key with push scope for `Converger.Agent`.

The first version (0.1.0) is published by hand ([#187](https://github.com/AimTune/converger/issues/187)).
