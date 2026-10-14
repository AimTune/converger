---
title: "ADR-0065: chativa as the reference client, a mekik/1 profile, and a seq cursor for history"
sidebar_label: "0065 chativa as reference client"
description: The unmodified chativa connector-mekik is Converger's reference WebSocket client, kept working by a CI suite that runs its code against a real server; mekik/1 clients get a profile without Converger-only frames; history pages backwards by seq and channel-scoped tokens list conversations.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-14 |
| **Issue** | [#65](https://github.com/AimTune/converger/issues/65) (client side: [AimTune/chativa#86](https://github.com/AimTune/chativa/issues/86)) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0062](0062-typed-message-payloads-on-message-activities.md), [ADR-0018](0018-keyset-pagination.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md) |

## Context and problem statement

[ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) made Converger Protocol v1 a superset of
mekik/1 so that chativa's `@chativa/connector-mekik` would work unchanged. Nothing checked it. Running chativa's
real connector against the native endpoint showed two breakages and three gaps:

1. **Converger-only frames render as chat bubbles.** mekik/1's open rule (section 4.5) says an unknown frame type
   is a rich message rendered by name. connector-mekik follows it: every frame that is not one of its own falls
   through to `onMessage`. chativa stamps every outgoing message with an `id`, Converger treats that as a
   `clientId` and answers with `ack`, then `deliveryStatus`; presence of other participants arrives as `presence`.
   Each of those became an empty bubble. The v1 text claimed mekik/1 clients "ignore the additions by the
   unknown-frame rule", which is not what mekik/1 says.
2. **Idle widgets were disconnected.** The server closes a connection after 60 s without inbound frames (4408).
   mekik/1 has no `ping` frame, and the server's text `heartbeat` was a bubble, not a keepalive.
3. chativa's `loadHistory(cursor)` opens at the newest messages and pages **backwards**; the REST list only paged
   forward from a watermark, and its activities carried no `seq`.
4. Agent-panel mode needs a conversation list; the client API had none (the tenant API's list needs the tenant API
   key and lists every channel).
5. `sendFile` needs the attachment message the upload created, in the shape the socket delivers.

The issue also asks that a broken chativa blocks Converger protocol changes in CI.

## Decision drivers

- An unmodified, released chativa connector must work: no Converger-specific code in connector-mekik.
- Full-protocol clients (`@converger/client`, the SDKs, the future `@chativa/connector-converger`) keep every frame.
- The compatibility check runs chativa's own code, not a re-implementation of its rules, and needs no browser.
- REST stays additive: existing request and response shapes keep working.

## Considered options

For the frames:

1. **A mekik/1 profile on the native endpoint**, selected by "no subprotocol and no `hello.protocol`".
2. **Fix it in chativa**: make connector-mekik drop unknown frames.
3. **Stop sending the additions to everyone** unless a client opts in.

For the compatibility check:

1. **Vendor chativa's TypeScript and run it in Node** (type stripping) against a real server from ExUnit.
2. **Headless browser running the chativa sandbox** in CI.
3. **Port `parseChatFrame` to Elixir** and test against the port.

For history:

1. **`before=<seq>` / `direction=backward` on the existing list**, `cursor` = seq.
2. **A new endpoint** for backward paging with an opaque cursor.

### Pros and cons of the options

#### mekik/1 profile

- Good, because unmodified mekik/1 clients get exactly the mekik/1 frame set, and every other client is untouched.
- Good, because the selector is what a mekik/1 client already does (mekik/1 defines no subprotocol, its `hello` has
  no `protocol`), while every Converger SDK already offers `converger.v1` and sends `hello.protocol`.
- Bad, because a hand-written client that offers no subprotocol and omits `hello.protocol` now loses `ack`; it must
  send either to get the full protocol.

#### Fix it in chativa

- Bad, because it contradicts mekik/1's open rule, which chativa implements correctly, and every other mekik/1
  client would hit the same problem.

#### Opt-in additions for everyone

- Bad, because it changes the default for the clients that already rely on `ack` and receipts.

#### Vendored chativa in Node

- Good, because it runs chativa's real `MekikConnector` (handshake, watermark, quick replies, interrupts, tool calls,
  GenUI routing) over a real socket in about a second per test, with no build step and no npm install.
- Bad, because the vendored copy must be refreshed by hand when chativa changes (documented in its README).

#### Headless browser

- Bad, because it needs a chativa build, a browser and a sandbox server in CI, for no extra coverage of the wire.

#### Elixir port

- Bad, because a port tests our reading of chativa, not chativa.

## Decision

Chosen: **the mekik/1 profile**, **vendored chativa in Node**, and **backward paging on the existing list**.

- **mekik/1 profile.** A native-endpoint connection that negotiated no WebSocket subprotocol and whose `hello` has no
  `protocol` (or `"mekik/1"`) does not receive `ack`, `deliveryStatus`, `presence`, `tokenRefreshed` or
  `replayTruncated`; its `heartbeat` is a WebSocket ping (the pong keeps it inside the idle timeout); `token_expired`
  and `token_revoked` are reported with the mekik/1 code `unauthorized` (number and close code unchanged), so a
  mekik/1 auth provider refreshes. Persistent frames are unchanged. Spec: Protocol v1 section 14.1.
- **Compatibility suite.** chativa's `ChatFrame.ts`, `GenUIComponentCache.ts` and connector-mekik's `index.ts` and
  `auth.ts` are vendored at a pinned commit under `test/protocol/fixtures/chativa/` (only two import specifiers
  rewritten). `test/protocol/chativa_compat_test.exs` (tags `:protocol`, `:chativa`) drives the real
  `MekikConnector` through a small Node harness against a Bandit-served endpoint and asserts what chativa's
  ChatEngine receives. It runs in the normal test run when Node >= 22.18 is on the PATH, is skipped otherwise, and
  fails instead when `CHATIVA_COMPAT=required`, which CI sets. A dedicated CI job, "chativa reference client
  compatibility", runs it with Node 24, so a protocol change that breaks chativa fails a named check.
- **History cursor.** `GET /api/v1/converger/conversations/:id/activities` accepts `before=<seq>` and
  `direction=backward`: the page just before `before` (or the newest page), still oldest first, with `cursor` (the
  oldest seq of the page, a string) for the next older page. Activities now carry `seq`. `format=frames` returns the
  page as Protocol v1 frames (`ConvergerWeb.Protocol.Frames.activity/3`, relative to the token's `user_id` or
  `?userId=`), which chativa routes like live frames. The seq is the cursor because it is already the protocol's
  public, gap-free position (ADR-0006); an opaque cursor would only hide it.
- **Conversation list.** `GET /api/v1/converger/conversations` lists the token's channel, most recently active first
  (keyset on `(updated_at, id)`, new index `conversations (channel_id, updated_at, id)`), with `status` and
  `updated_since` filters and a preview of the latest message (one lateral query). It needs a `scope: "channel"`
  token: an end user's token must not enumerate other users' conversations. Field names follow chativa's
  `Conversation` where one exists. `POST /conversations` accepts an optional `title`.
- **Upload result.** The upload response adds `seq`, the attachment `name`, and `frame`: the attachment message as
  the socket delivers it. REST sends without `from.id` (activities and uploads) are stored with the token's
  `user_id` as sender, so they render as `from: "user"` for that user, as socket sends do.

## Consequences

### Positive

- chativa's widget works against Converger with the published connector-mekik; the CI job keeps it working.
- `@chativa/connector-converger` (chativa#86) has every REST endpoint it needs: history, conversation list, upload
  result, receipts on the full protocol.
- Idle mekik/1 widgets stay connected.

### Negative and trade-offs

- A client without subprotocol and without `hello.protocol` no longer receives `ack` or receipts. All Converger SDKs
  and examples send both, and the spec now says how to opt in.
- The vendored chativa copy can drift from chativa's main branch; it is refreshed deliberately, with its SHA in the
  README.
- Keyset paging on `updated_at` can show a conversation twice or skip it when it becomes active between pages; the
  list is a starting point, and live state comes from the socket.

### Follow-ups

- [#64](https://github.com/AimTune/converger/issues/64): the channel-scoped native socket (`{conversationId, frame}`
  envelopes) for a single agent-panel connection, the `agent` participant role, and the live relay of a mekik bot
  (`run`, `genui_components`, `skills`, `resume`), which the suite should then cover end to end.
- [AimTune/chativa#86](https://github.com/AimTune/chativa/issues/86): `@chativa/connector-converger` on top of these
  endpoints, and a chativa sandbox preset pointed at Converger.

## Implementation

- Profile: `ConvergerWeb.Protocol.MekikProfile`, applied in `ConvergerWeb.ProtocolSocket` (which now receives the
  negotiated subprotocol from `ConvergerWeb.ProtocolSocketController`); `ConvergerWeb.Protocol.Session` records
  `hello.protocol`. Tests: `test/converger_web/protocol_socket_test.exs` ("mekik/1 profile").
- History and list: `ConvergerWeb.ConvergerAPI.ActivityController.index/2`, `ActivityJSON`,
  `ConversationController.index/2`, `Converger.Activities.last_messages/1`, the `updated_since` filter of
  `Converger.Conversations.paginate_conversations/2`, migration `20261014210000`. OpenAPI schemas
  `ActivitySet`, `ClientActivity`, `ClientConversationList`, `ClientConversationListItem`,
  `ClientConversationRequest`, `UploadResponse`. Tests:
  `test/converger_web/controllers/client_history_and_conversations_test.exs`, `api_contract_test.exs`.
- Compatibility suite: `test/protocol/chativa_compat_test.exs`, `test/protocol/fixtures/chativa/`, CI job `chativa`
  in `.github/workflows/ci.yml` (and Node 24 with `CHATIVA_COMPAT=required` in the coverage job).

## Links

- [Connecting chat clients (chativa)](../protocol/clients.md)
- [Protocol v1](../protocol/v1.md), sections 2.1, 5.4, 8.5, 14.1 and 15
- [Client API](../api/client-api.md): list conversations, history paging backwards, upload
- [chativa](https://github.com/AimTune/chativa), [mekik/1](https://github.com/AimTune/mekik/blob/main/PROTOCOL.md)
