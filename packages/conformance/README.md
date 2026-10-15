# Converger SDK conformance suite

Language-neutral test data that every Converger SDK runs in its own test suite
(`packages/client-python`, `packages/client-go`, `packages/client-elixir`, and
the TypeScript SDK). A behaviour change made here fails every SDK until each
one follows it.

| File | What it pins |
| --- | --- |
| `webhook-signatures.json` | Outbound webhook signature scheme: `sign` vectors (secret, timestamp, body, expected `x-converger-signature`) and `verify` vectors (headers, body, secret, fixed `now`, tolerance, expected result and error). Generated from the server's signer by `scripts/generate_signature_vectors.exs`; the server test `test/converger/channels/webhook_signature_vectors_test.exs` fails when they disagree. |
| `errors.json` | How a non-2xx response becomes the SDK error (`status`, `code`, `message`, `details`, `request_id`, `retry_after`), for the legacy error shapes and the standard envelope of #45. |
| `rest.json` | REST operations: the HTTP request each SDK must send and how it reads the response. |
| `agent.json` | Agent SDKs (#67): the wire exchange of an agent on a channel-scoped Protocol v1 connection, played by a fake server against each agent SDK (Go, .NET, Elixir; TypeScript and Python follow). See "Agent SDK rules" below. |
| `protocol.json` | Protocol v1 resume state machine: the `hello` frame, watermark tracking, duplicates, gaps, `sync`, acks, `replayTruncated`, `replay_unavailable`, `invalid_watermark`. |
| `integration/` | Fixtures and a runner for the end-to-end test against a real server. |

Regenerate the signature vectors after changing the signer (never edit them by hand):

```bash
mix run --no-start packages/conformance/scripts/generate_signature_vectors.exs
```

## Signature verification rules

`verify_signature(headers, body, secret, tolerance=300, now=current time)`:

1. Look up `x-converger-signature` case-insensitively. Absent or empty: `missing_signature`.
2. Empty secret (or an empty list of secrets): `no_secret`. A list of secrets is accepted for rotation.
3. Split the value on `,`, trim each part, split each part on the first `=`. Exactly the `t` part
   (an integer, `Integer.parse`-style: the whole value must be digits with an optional sign) and at least
   one `v1` part are required, otherwise `malformed_signature`. Unknown parts are ignored. The legacy
   `sha256=` form is `malformed_signature`: outbound webhooks never use it.
4. `|now - t| > tolerance`: `timestamp_out_of_tolerance` (the boundary itself is accepted).
5. Compute lowercase hex HMAC-SHA256 of `"<t>." + raw body bytes` for every secret and compare with
   every `v1` in constant time. No match: `invalid_signature`. Hex is compared as sent (uppercase hex is
   not accepted, as on the server).

## Protocol session rules

State: `watermark` (integer), `conversation_id` (or none), `sync_pending` (bool), `own` (set of seqs
acked to this connection above the watermark).

- `hello`: `{"type": "hello", "protocol": "converger/1", "watermark": W}` plus `conversationId` when
  known. The token travels in the `Authorization` header.
- `welcome`: when a conversation id was known and `data.conversationId` differs, reset `watermark` to 0
  and clear `own`. Store the id, clear `sync_pending`, deliver the frame.
- A frame with an integer `seq` (other than `ack`) is persistent:
  `seq <= watermark` or `seq` in `own`: drop (duplicate).
  `seq == watermark + 1`: deliver, advance, then absorb `own` (while `watermark + 1` is in `own`, advance
  and remove it), clear `sync_pending`.
  Otherwise (a gap): drop, and send `{"type": "sync", "watermark": watermark}` unless `sync_pending`;
  set `sync_pending`.
- `ack`: resolves the pending send. `seq == watermark + 1` advances (and absorbs); a higher `seq` is
  added to `own`; lower is ignored. Not delivered.
- `heartbeat`: `headSeq > watermark` and not `sync_pending`: send `sync`, set `sync_pending`. Not delivered.
- `replayTruncated`: deliver, send `sync` from the watermark, set `sync_pending`.
- `error` `replay_unavailable`: deliver, set `sync_pending`, schedule `sync` from the watermark after
  `data.retryAfterMs` (1000 when absent).
- `error` `invalid_watermark`: deliver, reset `watermark` to 0, clear `own`, send `sync` from 0, set
  `sync_pending`.
- `tokenRefreshed` is not delivered. Everything else (including unknown types) is delivered.

Transports add: reconnect with jittered exponential backoff on every close except 4400, 4401 (unless a
token provider returns a new token), 1008 and a normal close the client initiated; resume with the
session (same watermark and conversation id); re-send unacked sends with their original `clientId`.

## Agent SDK rules (`agent.json`)

An agent SDK (`packages/agent-go`, `packages/agent-dotnet`, `packages/agent-elixir`; #67) serves every
conversation of a `websocket` channel over one channel-scoped connection (docs/protocol/v1.md sections 9
and 10). Each SDK runs every scenario of `agent.json` in its tests:

1. Start an in-process fake server. Build the agent with the scenario's `agent` (`group`, initial
   `watermarks`), the fixture `token`, a short reconnect backoff (tens of ms), and the **fixture handler**.
2. Play `steps` in order:
   - `expect`: read the next frame the agent sent on the current connection (accept the agent's next
     connection first if there is none; skip `ping`) and match it against the pattern.
   - `send`: substitute captures, then write the frame to the agent.
   - `close`: close the current connection with that WebSocket close code. The agent must reconnect.
   Every connection must carry `Authorization: Bearer <token>`.
3. Validate every frame the agent sends: `hello` against `priv/protocol/v1/frames/client/hello.schema.json`,
   every enveloped frame against `priv/protocol/v1/frames/channel/client-envelope.schema.json`.

**Patterns.** `"$any"` matches any value; `"$capture:NAME"` matches a non-empty string and captures it;
`"{{NAME}}"` inside a string (also an object key, in `expect` and `send`) is replaced by the captured value.
Objects must have exactly the pattern's keys (no more, no fewer), arrays the same length, numbers compare
numerically, everything else is compared exactly. Generated ids (`clientId`, interrupt ids) are therefore
never pinned, but their reuse is (the `ack` answers the captured `clientId`, `resume` the captured interrupt id).

**The fixture handler** runs the ops of `handlers[turn.text]`, or of `handlers["*"]` when there is no entry,
stopping at the first failing op (the handler then fails):

| op | call | wire |
| --- | --- | --- |
| `text` | `reply.text(text, actions?)`; `{text}` is the turn's text, `{answer}` the last `ask` answer (a string) | `{type: "text", clientId, data: {text}, actions?}`, waits for the `ack` |
| `ask` | `reply.ask(payload, actions)` | `interrupt {id, data: {payload, actions}}`; after `resume {answers: {id: answer}}`, `interrupt_resolved {id, data: {answer}}` |
| `typing` | `reply.typing(on)` | `{type: "typing", isTyping}` |
| `toolCall` | `reply.toolCall({id, name, status, params?, result?})` | `{type: "tool_call", data: {...}}` |
| `message` | `reply.message(type, data)` | `{type, clientId, data}`, waits for the `ack` |

**Agent behaviour the scenarios pin:**

- `hello` is `{"type": "hello", "protocol": "converger/1"}` plus `group` when configured and `watermarks`
  (conversation id to the last seq seen) when non-empty. The token travels in the `Authorization` header.
- Conversation frames are `{conversationId, frame}` both ways. A frame with an integer `seq` (other than
  `ack`) at or below the conversation's watermark is a duplicate and dropped; otherwise it moves the
  watermark. `ack` seqs do not move it.
- A turn is a message frame with `from: "user"` and a `seq` (not `typing`, `event`, `conversationUpdate`, ...).
  `from: "bot"` frames (the agent's own replies, other bots, human agents) are never turns.
- Each turn runs between `run {status: "started"}` and `run {status: "finished"}`; a failing handler ends
  with `run {status: "error"}`. Turns of one conversation run one at a time, in order; `resume` is
  dispatched to the waiting `ask` immediately, never queued behind turns.
- Message sends carry a generated `clientId` and wait for the `ack`; an `error` frame naming that `clientId`
  fails the send with the error's `code`. After a reconnect, unacked sends are re-sent with the same
  `clientId` once the `welcome` arrived.
- Interrupt ids must not have the `clientId` syntax (`[A-Za-z0-9._:~-]{1,128}`): the SDKs use
  `ask/<random>#<n>`. Otherwise the server would treat the id as the frame's idempotency key (v1 section 7),
  and the `interrupt_resolved` with the same id would be taken for a duplicate of the `interrupt`.
