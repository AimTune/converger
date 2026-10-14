# Converger.Agent

.NET agent SDK for [Converger](https://converger.aimtune.dev): a bot backend that answers the conversations of a
Converger channel over one channel-scoped [Protocol v1](https://converger.aimtune.dev/protocol/v1) WebSocket
(sections 9 and 10). Turns, text and rich replies, tool-call traces, interrupts (ask), reconnect with resume and
per-conversation watermarks. The Go and Elixir agent SDKs have the same model and wire behaviour.

Full documentation: [converger.aimtune.dev/sdk/agent-dotnet](https://converger.aimtune.dev/sdk/agent-dotnet).

## Install

```bash
dotnet add package Converger.Agent
```

Not yet published to NuGet; until then reference `src/Converger.Agent/Converger.Agent.csproj`. Targets `net8.0`
and later, no dependencies beyond the BCL (`ClientWebSocket`, `System.Text.Json`).

## Quick start

The agent authenticates with a **channel-scoped token** of its `websocket` channel
(`POST /api/v1/converger/tokens/generate` with `{"scope": "channel"}`), sent as `Authorization: Bearer` on the
upgrade. Tokens expire: pass a `TokenProvider`, which is called on every connect.

```csharp
using Converger.Agent;

var agent = new ConvergerAgent(new AgentOptions
{
    Url = ConvergerAgent.SocketUrl("https://chat.example.com"), // wss://chat.example.com/socket/converger/v1
    TokenProvider = async ct => await FetchChannelTokenAsync(ct), // or Token = "..."
    Group = "faq-bot",                                              // optional agent group
    OnError = e => logger.LogWarning(e, "agent"),
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
    await reply.ToolCallAsync(new ToolCall { Id = "t1", Name = "search_faq", Status = "running" }, ct);
    await reply.TextAsync($"You said: {turn.Text}", [new AgentAction("Talk to a human", "/human")], ct);
});

await agent.RunAsync(cancellationToken); // returns after cancellation; throws ConvergerCloseException when refused for good
```

A runnable echo agent is in `examples/EchoAgent` (`CONVERGER_URL`, `CONVERGER_TOKEN`).

## API

| | |
| --- | --- |
| `new ConvergerAgent(AgentOptions)` | `Url` (required), `Token` or `TokenProvider` (required), `Group`, `UserId`, `Watermarks` (seed), `BackoffInitial` (500 ms), `BackoffMax` (30 s), `AckTimeout` (30 s), `Headers`, `OnError` |
| `ConvergerAgent.SocketUrl(baseUrl)` | `https://h` becomes `wss://h/socket/converger/v1` |
| `agent.OnTurn((turn, reply, ct) => Task)` | the turn handler; `ct` is cancelled when the agent stops |
| `agent.RunAsync(ct)` | connect, reconnect and dispatch until `ct` is cancelled or the server refuses for good |
| `agent.Watermarks` | snapshot of the last seq seen per conversation; persist it and pass it back as `AgentOptions.Watermarks` |
| `reply.TextAsync(text, actions?, ct)` | text message with optional chips; waits for the ack, returns `Ack` |
| `reply.MessageAsync(type, data, ct)` | any message type (buttons, card, carousel, image, file, ...); waits for the ack |
| `reply.AskAsync(payload, actions?, ui?, ct)` | sends an `interrupt`, waits for the user's answer, sends `interrupt_resolved`, returns the answer as `JsonElement` |
| `reply.ToolCallAsync(ToolCall, ct)` | a `tool_call` trace (`Id`, `Name`, `Status`, `Description`, `Params`, `Result`, `Error`, `StartedAt`, `EndedAt`; nulls omitted) |
| `reply.TypingAsync(on, ct)` | typing indicator (dropped while disconnected) |
| `reply.SendAsync(JsonObject frame, ct)` | a raw agent frame, no ack |
| `reply.End()` / `reply.EndAsync()` | sends `run {status: "finished"}` now; called for you when the handler returns |

`Turn`: `ConversationId`, `Id`, `Seq`, `Text` (`data.text`, `""` without text), `Message` (`Type`, `Data`, `Raw`),
`Participant` (`Id`, `Role`, `Name`; null when absent), `Meta` (per-turn context, never stored), `Metadata`, `Action`
(the tapped button, `metadata.action`), `ReplyTo`, `Timestamp`.

`AgentAction(label, value?, url?)`: `value` is any JSON value (`JsonNode`, so strings, numbers and booleans convert
implicitly); omitted when null, in which case the answer is the label.

## Semantics

- **Turns.** A frame with `from: "user"`, an integer `seq` and a message type is a turn; `typing`, `presence`,
  `deliveryStatus`, `event`, `conversationUpdate`, `run`, `genui_components`, `skills`, `heartbeat` and
  `replayTruncated` are not, and `from: "bot"` frames never are. Turns of one conversation run one at a time, in
  order; different conversations run concurrently. A `resume` is never blocked by the queue: an ask waits inside
  the handler while the conversation's next turn stays queued.
- **Runs.** Each handler is wrapped in `run {status: "started"}` and `run {status: "finished"}`. A thrown exception
  sends `run {status: "error"}` and goes to `OnError`. When the agent stops, nothing is sent.
- **Sends.** Messages carry a `clientId` (`agent-<16 hex>`) and wait for the `ack`. A refused send throws a
  `ConvergerException` (`Code`, `Message`, `Number`, `Retryable`, `RetryAfter`, `ClientId`, `FrameType`,
  `Details`, `ConversationId`); no ack within `AckTimeout` throws `ConvergerAckTimeoutException`. Unacked sends are
  re-sent with the same `clientId` after a reconnect, in order with the frames written while disconnected.
- **Asks.** The interrupt id is `ask/<16 hex>#<n>`, deliberately not of the clientId syntax: no ack is expected and
  the server does not dedupe the interrupt against its `interrupt_resolved`. An answer to an unknown interrupt goes
  to `OnError` with code `unknown_interrupt`.
- **Watermarks.** Every enveloped frame with an integer `seq` (except `ack`) advances the conversation's
  watermark; a frame at or below it is a duplicate and dropped. `hello.watermarks` carries them on every connect,
  so the server replays what the agent missed.
- **Reconnect.** Jittered exponential backoff (`BackoffInitial` to `BackoffMax`); a close reason
  `{"retryAfterMs": N}` (1012, 4503) sets the delay. Close 4401 retries once at once with a fresh token; a second
  4401 in a row, 4400, 4403 and 1008 end `RunAsync` with `ConvergerCloseException` (`Code`, `Reason`, `Last`: the
  last connection-level error frame). The agent pings every `idleTimeoutMs / 2` of the welcome (default 60 s).
- **Stop.** Cancelling `RunAsync`'s token returns cleanly: running handlers are cancelled and awaited, pending sends
  and asks fail (`ConvergerStoppedException`, an `OperationCanceledException`).

## Testing

```bash
cd packages/agent-dotnet
dotnet build -warnaserror
dotnet test
```

The tests run an in-process Kestrel WebSocket server: every scenario of the shared fixture
`packages/conformance/agent.json` (as the Go and Elixir agent SDKs do), every frame the agent sends validated
against the Protocol v1 schemas in `priv/protocol/v1` with JsonSchema.Net, plus reconnect, auth, error and
concurrency cases.
