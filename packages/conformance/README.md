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
