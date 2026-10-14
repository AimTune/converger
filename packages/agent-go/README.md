# converger-agent-go

Agent SDK for [Converger](https://converger.aimtune.dev) in Go: a bot backend answers the conversations of a
Converger channel (web widget, WhatsApp, Telegram, ... routed to it) over one channel-scoped
[Protocol v1](https://converger.aimtune.dev/protocol/v1) WebSocket. Turns arrive with their text, typed message,
participant and per-turn meta; the handler replies with text, rich messages, tool-call traces, typing, and
`Ask`, which pauses on an interrupt until the user answers (a tapped button on any channel).

```bash
go get github.com/AimTune/converger/packages/agent-go
```

Go 1.22+, one dependency (`github.com/coder/websocket`). Not published yet; releases will be tags
`packages/agent-go/vX.Y.Z`. Full documentation: [converger.aimtune.dev/sdk/agent-go](https://converger.aimtune.dev/sdk/agent-go).

## Quick start

```go
import agent "github.com/AimTune/converger/packages/agent-go"

a := agent.New(agent.SocketURL("https://chat.example.com"), agent.StaticToken(channelToken),
	agent.WithGroup("faq-bot"),                                  // optional: share the channel with other processes
	agent.OnError(func(err error) { log.Printf("agent: %v", err) }))

a.OnTurn(func(ctx context.Context, turn *agent.Turn, reply *agent.Reply) error {
	if turn.Text == "refund" {
		answer, err := reply.Ask(ctx, map[string]any{"title": "Refund 249.90 TRY?"},
			agent.Action{Label: "Yes", Value: "yes"}, agent.Action{Label: "No", Value: "no"})
		if err != nil {
			return err
		}
		_, err = reply.Text(ctx, fmt.Sprintf("You answered %v.", answer))
		return err
	}
	_, err := reply.Text(ctx, "You said: "+turn.Text)
	return err
})

err := a.Run(ctx) // blocks; nil after ctx is cancelled, *agent.CloseError when the server refuses for good
```

The token is a channel-scoped Converger token of a `websocket` channel:
`POST /api/v1/converger/tokens/generate` with the channel secret and `{"scope": "channel"}`. Pass a
`TokenSource` that fetches a fresh one to survive token expiry (close 4401). A runnable example is in
[`examples/echo`](examples/echo/main.go).

## API

| | |
| --- | --- |
| `New(url, token, opts...)` | `WithGroup`, `WithUserID`, `WithWatermarks`, `WithBackoff`, `WithAckTimeout`, `WithHeader`, `OnError` |
| `OnTurn(handler)` / `Run(ctx)` | one handler for every user turn; `Run` connects, reconnects and dispatches |
| `Watermarks()` | the last seq seen per conversation; persist it and pass it to `WithWatermarks` after a restart |
| `Turn` | `ConversationID`, `ID`, `Seq`, `Text`, `Message{Type, Data, Raw}`, `Participant`, `Meta`, `Metadata`, `Action` (the tapped button), `ReplyTo`, `Timestamp` |
| `reply.Text(ctx, text, actions...)` | a `text` message (quick-reply chips optional); waits for the ack, returns `*Ack{ID, Seq}` |
| `reply.Message(ctx, type, data)` | any message type (`buttons`, `card`, `carousel`, `image`, `file`, ...); waits for the ack |
| `reply.Ask(ctx, payload, actions...)` / `AskWith` | sends an `interrupt`, waits for the answer, sends `interrupt_resolved`, returns the answer |
| `reply.ToolCall(ctx, ToolCall{...})` | a `tool_call` trace (upserted by id: running, then completed or error) |
| `reply.Typing(ctx, on)` | typing indicator |
| `reply.Send(ctx, frame)` | any agent frame, raw (`genui`, `skill`, ...) |
| `reply.End()` | sends `run finished` now (otherwise sent when the handler returns) |

## Semantics

- Each turn runs between transient `run {status: "started"}` and `run {status: "finished"}`; a handler error or
  panic sends `run {status: "error"}` and goes to `OnError`.
- Turns of one conversation run one at a time, in order; different conversations run concurrently. An `Ask`
  waiting for its answer keeps the conversation's next turn queued, while the answer itself is never queued.
- Message sends carry a generated `clientId` and wait for the server's `ack`; a refused send returns an
  `*agent.Error` (`Code`, `Message`, `Retryable`, `RetryAfter`, `Details`, ...). Unacked sends are re-sent with
  the same `clientId` after a reconnect (the server de-duplicates them); frames written while disconnected are
  sent after the next `welcome`, in order (typing excepted).
- Reconnects use jittered exponential backoff (500 ms to 30 s) and the server's `retryAfterMs` close reason.
  `hello.watermarks` resumes every conversation from the last seq seen, so turns committed while the agent was
  away are replayed; frames at or below the watermark are dropped as duplicates.
- Close 4401 is retried once with a fresh token; 1008, 4400, 4403 and a second 4401 end `Run` with a
  `*agent.CloseError`.
- Frames from the bot side (`from: "bot"`: this agent, other bots, human agents) are never turns.

## Tests

```bash
go vet ./... && go test -race -count=1 ./...
```

`TestConformance` plays every scenario of the shared fixture
[`packages/conformance/agent.json`](../conformance/agent.json) against an in-process fake server and validates
every frame the agent sends against `priv/protocol/v1/frames/channel/client-envelope.schema.json`.
