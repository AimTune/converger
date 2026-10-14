---
title: mekik
description: The mekik channel adapter (Mode A of #64) - Converger dials a mekik/1 bot server per conversation, sends the end user's turns and interrupt answers upstream, and stores and relays the bot's frames.
sidebar_position: 4.1
---

**Implemented ([#64](https://github.com/AimTune/converger/issues/64), Mode A).** A `mekik` channel
makes a [mekik](https://github.com/AimTune/mekik) server the bot of the conversations routed to it.
Converger dials the server, one WebSocket per conversation, and speaks
[mekik/1](https://github.com/AimTune/mekik/blob/main/PROTOCOL.md) to it as a client would: any
stock mekik server (for example `node examples/refund.ts --serve` from the mekik repository) works
unchanged. The end user can be on any channel: the web widget, WhatsApp, Telegram, Slack, email,
SMS. The design is recorded in [ADR-0066](../adr/0066-mekik-channel-adapter-mode-a.md).

```text
end user (WhatsApp, widget, ...) ──▶ Converger ──routing rule──▶ mekik channel ══ WebSocket per conversation ══▶ mekik server
                                 ◀── reply-back routing ◀── stored bot frames ◀══ text, tool_call, interrupt, ... ══
```

## Mode A and Mode B

| | Mode A: Converger dials mekik (this page) | Mode B: mekik dials Converger |
| --- | --- | --- |
| Who connects | the `mekik` channel adapter opens one upstream WebSocket per conversation | the mekik transport `@mekik/converger` connects to a `websocket` channel's channel-scoped socket ([WebSocket channel](websocket.md#agents-and-bots-on-the-native-endpoint-protocol-v1)) |
| mekik changes | none | mekik runs with an external transcript (AimTune/mekik#47) |
| Transcripts | **two**: mekik records its own, Converger records again | one: Converger's |
| `seq` spaces | **two**: mekik's per-conversation `seq` (used only as the upstream watermark) and Converger's | one: Converger's |
| Public endpoint | the mekik server must be reachable from Converger | mekik needs none |
| Status | Implemented | Planned (#64, AimTune/mekik#47) |

Mode B is the recommended steady state; Mode A works today with any mekik server.

## Setup

1. Run a mekik server, for example the refund demo of the mekik repository:

   ```bash
   cd mekik/ts && pnpm install && pnpm build && node examples/refund.ts --serve   # ws://localhost:8800
   ```

2. Create a channel of type `mekik` (mode `duplex`, the only mode it supports) with the server's
   URL, in the admin panel, the tenant portal or the API:

   ```json
   { "name": "refund bot", "type": "mekik", "mode": "duplex",
     "config": { "url": "wss://bot.example.com/ws", "token": "...", "meta": { "brand": "acme" } } }
   ```

3. Add a [routing rule](../concepts/routing-rules.md) from the end user's channel (a WhatsApp
   number, the web widget's `websocket` channel, ...) to the `mekik` channel.

From then on, every message of a conversation on the end user's channel reaches the bot, and the
bot's answers go back to the end user by [reply-back routing](../concepts/routing-rules.md#how-activities-fan-out).

## Configuration

| Key | Required | Meaning |
| --- | --- | --- |
| `url` | yes | The mekik/1 WebSocket endpoint, `ws://` or `wss://`. Checked against the outbound SSRF guard (`WEBHOOK_ALLOW_PRIVATE_TARGETS`, `WEBHOOK_ALLOWED_TARGETS`, see [webhooks](../webhooks.md)) when the channel is saved. Credentials in the URL are refused; use `token`. |
| `token` | no (secret) | Sent as `hello.token` and as an `Authorization: Bearer` header (mekik/1 section 7). Masked in the admin UI; the whole config is encrypted at rest. |
| `meta` | no | A JSON object of mekik/1 client meta: sent as `hello.meta` and merged into every turn's `meta` (mekik/1 section 6; the server's `acceptClientMeta` decides what the graph sees). |
| `bot_id` | no | The sender of the bot's activities. Default `mekik`. |
| `idle_timeout_seconds` | no | A conversation's upstream connection without traffic for this long is closed (1 to 86 400, default 300). The next turn opens a new one, which resumes. |

Operator settings (`config :converger, Converger.Channels.Adapters.Mekik`): `connect_timeout_ms`
(10 000), `call_timeout_ms` (15 000, how long a delivery waits for the connection),
`backoff_base_ms` (1 000) and `max_backoff_ms` (30 000) for reconnects, `auth_retry_ms` (60 000,
the wait after a rejected token) and `relay_scan_interval_ms` (60 000, see [cluster](#cluster)).

## Mapping

### End user to mekik

The pipeline delivers the conversation's activities to the channel. The adapter renders each one as
the bot sees it (`ConvergerWeb.Protocol.Frames.activity/3`, the end user's side is `user`) and sends
only the end user's turns:

| Converger | mekik/1 frame |
| --- | --- |
| a text message of the end user | `{"type": "text", "data": {"text": "..."}, "meta": {...}}` (attachments stay in `data.attachments`) |
| a rich message of the end user (an image, a shared location, a contact, ...) | a `text` turn with the message's fallback text, carrying the typed message under `data.message` (`{type, id, data}`): mekik/1 has no other user turn, and a graph's `input` function can read it |
| a turn whose `replyTo` names an open `interrupt` (a tapped WhatsApp button, a chativa chip) | `{"type": "resume", "answers": {"<interrupt id>": value}}`, `value` being `metadata.action.value`, else the label, else the text ([messages.md section 6](../protocol/messages.md)) |
| a native `resume`, `genui_event`, `client_tools`, `client_skills`, `abort` from an end user's socket | forwarded unchanged ([protocol section 9](../protocol/v1.md#9-the-bot-channel-and-mekik-relay-implemented-64)) |
| the bot's own replies, other agents, lifecycle events | not sent (the delivery is marked sent with `skipped: "not an end-user turn"`) |

A turn's `meta` is the end user's per-turn `meta` (relayed ahead of the turn, never stored), under the
channel's `meta`, under Converger's context:

```json
{ "locale": "tr-TR", "brand": "acme",
  "conversationId": "c0a8012e-...", "channel": { "id": "...", "type": "whatsapp_meta" },
  "participant": { "id": "...", "externalId": "+905551112233" } }
```

### mekik to Converger

| mekik/1 frame | Converger |
| --- | --- |
| `text` with `from: "bot"`, rich message frames | a `message` activity of the bot (`bot_id`), the frame stored losslessly as a typed payload ([messages.md section 4](../protocol/messages.md)); the mekik message `id` is kept |
| `text` with `from: "user"` (fan-out echo, replay of the end user's own turn) | skipped: Converger already has the turn |
| `tool_call`, `genui`, `interrupt`, `interrupt_resolved`, `skill` | `message` activities with `message_type = frame.type`, the frame body kept verbatim; channels without a native renderer get the text fallback (an interrupt's actions become WhatsApp buttons) |
| `run` | relayed to the conversation's connections; `run started` shows the bot typing until the run ends |
| `genui_components`, `skills`, `error` | relayed to the conversation's connections |
| `typing` (chativa) | the bot's typing signal |
| `welcome` | the mekik conversation and user are recorded; see [resume](#resume-and-exactly-once-storage) |
| `error` `unauthorized` and close `4401` | the waiting deliveries fail permanently (dead-lettered, [replayable](../concepts/deliveries.md#dead-letters)); the next attempt waits `auth_retry_ms` |

The bot's activities are stored with the `mekik` channel as their source, so reply-back routing
delivers them to the end user's channel, and Converger numbers them in the conversation's own `seq`
space.

## Connections

`Converger.Channels.Mekik.Connections` is a `DynamicSupervisor` of one connection process per
(mekik channel, conversation), started on the first turn delivered to the channel or the first bot-only
frame of an end user. Each connection:

- asserts its identity in the URL query string (`userId`, `conversationId`, `watermark`, for L7
  affinity, mekik/1 section 1) and in `hello` (which wins). The `userId` is the conversation's
  participant id (so mekik's per-user store spans the participant's conversations), else
  `converger:<conversation id>`; a verified `userId` returned by the server replaces it;
- waits for `welcome` before it sends anything (a delivery waits up to `call_timeout_ms`);
- reconnects after a lost connection with exponential backoff (doubling from `backoff_base_ms` up to
  `max_backoff_ms`) plus up to 50 % random jitter; a delivery while it is backing off fails and is
  retried by the channel's retry policy;
- closes after `idle_timeout_seconds` without traffic.

### Resume and exactly-once storage

A mekik server mints its own `conversationId` on the first connect and adopts an asserted one only when
it exists and belongs to the connecting user. The adapter records the pair from `welcome` in the
`mekik_sessions` table (one row per mekik channel and conversation), with the highest mekik `seq` it
handled as the watermark, and asserts both on every later connect: the server replays exactly the
frames Converger missed (while disconnected, while restarting). When the server hands back a different
conversation (the old one is gone, for example after a restart of a mekik server with an in-memory
store), the watermark starts over at 0, as mekik/1 requires.

A persistent frame with a `seq` at or below the watermark is skipped, and each stored frame's
idempotency key names the mekik conversation and `seq`, so a replay is never stored twice, even when
the watermark was not written yet (it is written lazily, about once a second, and when the connection
stops). A frame that cannot be stored (the database is unavailable) is not acknowledged: the
connection reconnects and the server replays it.

### Cluster

A connection is registered globally (`:global`), so a conversation has one upstream connection in the
cluster. `Converger.Channels.Mekik.Relay` (one per node) receives the end users' bot-only frames and
per-turn `meta`: the node that runs a conversation's connection forwards its frames; when none runs,
the node chosen by rendezvous hashing of the conversation starts one. The relay follows the active
`mekik` channels found by a scan (after boot, then every `relay_scan_interval_ms`) and every channel a
delivery touches.

## Limitations

- **Two transcripts and two `seq` spaces.** mekik records the conversation in its own history store,
  Converger records it again; Converger ignores mekik's `seq` except as the upstream watermark. A
  replayed or re-numbered mekik transcript does not change Converger's.
- **The turn lock is the bot's.** A turn sent while a run is in flight draws mekik's `error` `busy`
  (or `interrupted` while the thread is parked on an interrupt); it is relayed to the end user's
  connections, and the delivery still counts as sent.
- **One upstream connection per conversation.** Many idle conversations cost one socket each until
  `idle_timeout_seconds`.
- **User turns are `text`.** Rich user messages reach the graph as text with the typed message under
  `data.message`; `survey`, `regenerate` and `edit` are forwarded but a stock mekik server answers
  them with `bad_request`.
- **The URL is checked when the channel is saved**, not pinned at connect time.

## Testing

`test/converger/channels/mekik_integration_test.exs` runs the adapter end to end against a fake mekik/1
server (`test/support/mekik/`): a scripted refund turn (`run`, `tool_call`, an approval `interrupt`),
the end user's tapped button reaching the server as `resume`, replay after a reconnect, resume after a
restart, rejected tokens and idle eviction. `test/converger/channels/mekik_live_test.exs` (tag `:mekik`,
excluded by default) runs the same scenario against a real server:

```bash
node examples/refund.ts --serve        # in mekik/ts
MEKIK_URL=ws://127.0.0.1:8800/ws mix test --only mekik
```

## Related

- [Protocol v1, section 9: the bot channel and mekik relay](../protocol/v1.md#9-the-bot-channel-and-mekik-relay-implemented-64) and [section 14: mekik/1 compatibility](../protocol/v1.md#14-mekik1-compatibility)
- [Typed messages](../protocol/messages.md)
- [WebSocket channel](websocket.md): channel-scoped sockets for Mode B and other agents
- [ADR-0066](../adr/0066-mekik-channel-adapter-mode-a.md), [ADR-0063](../adr/0063-channel-scoped-agent-sockets-and-the-bot-relay.md)
