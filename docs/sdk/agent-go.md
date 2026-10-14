---
title: Agent SDK for Go (converger-agent-go)
description: Write a Converger agent in Go - one channel-scoped WebSocket serves every conversation of a channel, with turns, text and rich replies, tool-call traces, interrupts (ask), reconnect and per-conversation watermarks.
sidebar_position: 7
---

# Agent SDK for Go

**Implemented (#67)**, not yet published. `packages/agent-go` (module
`github.com/AimTune/converger/packages/agent-go`, package `agent`) is the Go agent SDK: a bot backend answers
the conversations of a Converger channel over one channel-scoped Protocol v1 connection
([Protocol v1, sections 9 and 10](../protocol/v1.md#10-channel-scoped-sockets-implemented-64-on-the-native-endpoint)).
Users on WhatsApp, Telegram or the web widget write to their channel, a [routing rule](../concepts/routing-rules.md)
targets the agent's `websocket` channel, and the agent's replies are stored and routed back to each user's
channel ([WebSocket channel type](../channels/websocket.md#agents-and-bots-on-the-native-endpoint-protocol-v1)).

The .NET and Elixir SDKs have the same model and wire behaviour: [.NET](agent-dotnet.md), [Elixir](agent-elixir.md).

## Install

```bash
go get github.com/AimTune/converger/packages/agent-go
```

Go 1.22+, one dependency (`github.com/coder/websocket`). Releases will be tags `packages/agent-go/vX.Y.Z`.

## Token

The agent authenticates with a **channel-scoped token** of the agent's `websocket` channel:

```bash
curl -X POST https://chat.example.com/api/v1/converger/tokens/generate \
  -H "Authorization: Bearer $BOT_CHANNEL_SECRET" -H "content-type: application/json" \
  -d '{"scope": "channel"}'
```

It travels in the `Authorization: Bearer` header of the upgrade. Tokens expire (default 30 minutes): pass a
`TokenSource` that returns a fresh one on every connect, and the agent survives the expiry close (4401).

## Usage

```go
import agent "github.com/AimTune/converger/packages/agent-go"

a := agent.New(agent.SocketURL("https://chat.example.com"), fetchChannelToken,
	agent.WithGroup("faq-bot"),
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
	_ = reply.Typing(ctx, true)
	_ = reply.ToolCall(ctx, agent.ToolCall{ID: "t1", Name: "search_faq", Status: "running"})
	_, err := reply.Text(ctx, "You said: "+turn.Text, agent.Action{Label: "Talk to a human", Value: "/human"})
	return err
})

if err := a.Run(ctx); err != nil { // nil after ctx is cancelled
	log.Fatal(err) // *agent.CloseError: the server refused for good (4401 twice, 4403, 4400, 1008)
}
```

### Turn

| field | |
| --- | --- |
| `ConversationID`, `ID`, `Seq` | the conversation, the activity id and its seq |
| `Text` | `data.text` (`""` for messages without text) |
| `Message` | `Type`, `Data`, `Raw` (the whole frame): images, files, locations, ... arrive typed ([messages](../protocol/messages.md)) |
| `Participant` | the sender (`ID`, `Role`, `Name`) |
| `Meta` | the turn's per-turn context (mekik/1 `meta`, for example the locale), never stored |
| `Metadata`, `Action` | the stored activity metadata; `Action` is the tapped button (`metadata.action`) |
| `ReplyTo` | `{id, seq}` of the activity the turn answers |

### Reply

| method | frame | |
| --- | --- | --- |
| `Text(ctx, text, actions...)` | `text` with frame-level `actions` chips | waits for the `ack`, returns `*Ack{ID, Seq, Duplicate}` |
| `Message(ctx, type, data)` | any message type (`buttons`, `card`, `carousel`, `quick-reply`, `image`, `file`, ...) | waits for the `ack` |
| `Ask(ctx, payload, actions...)`, `AskWith(ctx, payload, AskOptions{Actions, UI})` | `interrupt`, then `interrupt_resolved` | returns the answer: the tapped action's `value`, else its label or the user's text |
| `ToolCall(ctx, ToolCall{...})` | `tool_call` | upserted by `ID` on the client: `running`, then `completed` or `error` |
| `Typing(ctx, on)` | `typing` | dropped while disconnected |
| `Send(ctx, frame)` | any agent frame (`genui`, `skill`, ...) | raw, no ack |
| `End()` | `run {status: "finished"}` | sent for you when the handler returns |

An `Ask` is answered by the user's `resume` frame or by a turn that answers the interrupt (a tapped WhatsApp
button, a chativa chip): the server turns both into `resume {answers: {id: value}}` for the agent
([section 9](../protocol/v1.md#9-the-bot-channel-and-mekik-relay-implemented-64)). Interrupt ids are
`ask/<random>#<n>`, which deliberately do not have the `clientId` syntax: the server does not key the
`interrupt` and its `interrupt_resolved` by them.

## Behaviour

- **Runs.** Each turn runs between transient `run {status: "started"}` and `run {status: "finished"}`
  frames, relayed to the user's connections; a handler error or panic sends `run {status: "error"}` and
  goes to `OnError`.
- **Ordering.** Turns of one conversation run one at a time, in order; conversations run concurrently. While
  an `Ask` waits, the conversation's next turn stays queued; the answer itself is dispatched immediately.
- **Idempotent sends.** Every message send has a generated `clientId` and waits for the `ack` (default 30 s,
  `WithAckTimeout`). A refused send returns an `*agent.Error` with the server's `Code`, `Message`,
  `Retryable`, `RetryAfter` and `Details` ([errors](../protocol/v1.md#12-errors)). After a reconnect, unacked
  sends are re-sent with the same `clientId`, so the server stores each once; frames written while
  disconnected are sent after the next `welcome`, in order (typing excepted).
- **Resume.** The agent tracks the last `seq` seen per conversation and sends it as `hello.watermarks` on every
  reconnect: turns committed while it was away are replayed, duplicates dropped. `Watermarks()` and
  `WithWatermarks` carry the position across restarts.
- **Reconnect.** Jittered exponential backoff (500 ms to 30 s, `WithBackoff`), or the server's
  `retryAfterMs` close reason (1012 draining, 4503). Close 4401 is retried once with a fresh token; 1008, 4400,
  4403 and a second 4401 end `Run` with a `*agent.CloseError` carrying the last `error` frame.
- **Groups.** `WithGroup("name")` joins an agent group (`hello.group`): several processes behind one channel
  share its conversations, each served by one of them.
- **Not turns.** Frames from the bot side (`from: "bot"`: this agent's replies, other bots, human agents),
  typing, receipts and lifecycle events are not passed to the handler.

Planned: token streaming (`genui` text chunks) and a turn history accessor, as in the TypeScript and Python
SDKs (#67).

## Tests and conformance

```bash
cd packages/agent-go && go vet ./... && go test -race -count=1 ./...
```

`TestConformance` plays every scenario of the shared fixture `packages/conformance/agent.json` (a text turn,
duplicates and bot frames, an `ask` with a queued second turn, rich replies, a refused send, a reconnect
with watermarks and a re-sent unacked reply) against an in-process fake server, and validates every frame
the agent sends against the Protocol v1 schemas (`frames/channel/client-envelope.schema.json`). The rules
are in `packages/conformance/README.md`. The SDK was also run end to end against a local server: a widget
user's turn reached the agent, and both its reply and an `Ask` answered with `resume` came back to the user.
`examples/echo` is the agent used for that check.
